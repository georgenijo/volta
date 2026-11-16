#!/usr/bin/env python3
"""HTTP/2 front end for the synthetic startup fixture.

The live API negotiates HTTP/2, where parallel requests share one TLS
connection. `startup-fixture.py` speaks HTTP/1.1 only, so every parallel
request opens its own connection there. This front end terminates TLS on
IPv4 loopback with ALPN `h2` and forwards each stream concurrently to that
fixture running with `--plain` on another loopback port:

    python3 scripts/startup-fixture.py --plain --port 9444 \
      --profile server-2026-11-rtt150 --log /tmp/startup.jsonl
    python3 scripts/startup-fixture-h2.py --cert /tmp/localhost.crt \
      --key /tmp/localhost.key --upstream 9444 --profile server-2026-11-rtt150

It needs the `h2` package (`pip install h2`, in a scratch virtual env). The
simulated link charges two round trips per client connection (TCP and TLS
1.3) here, and the fixture charges one per request. Like the fixture, it
never logs headers or bodies.
"""
from __future__ import annotations

import argparse
import asyncio
import http.client
import importlib.util
import json
import ssl
from pathlib import Path

import h2.config
import h2.connection
import h2.events
import h2.exceptions

HOST = "127.0.0.1"
HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "upgrade", "te", "host"}


def load_profiles() -> dict[str, dict[str, int]]:
    path = Path(__file__).with_name("startup-fixture.py")
    spec = importlib.util.spec_from_file_location("startup_fixture", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module.PROFILE_LATENCIES


class FrontEnd:
    def __init__(self, upstream: int, profile: str) -> None:
        self.upstream = upstream
        self.profiles = load_profiles()
        if profile not in self.profiles:
            raise SystemExit("unknown latency profile")
        self.profile = profile

    def rtt(self) -> float:
        return self.profiles[self.profile].get("rtt", 0) / 1_000

    def forward(self, method: str, path: str, headers: list[tuple[str, str]], body: bytes) -> tuple[int, list[tuple[str, str]], bytes]:
        connection = http.client.HTTPConnection(HOST, self.upstream, timeout=60)
        try:
            outgoing = {name: value for name, value in headers if not name.startswith(":") and name not in HOP_BY_HOP}
            connection.request(method, path, body=body or None, headers=outgoing)
            response = connection.getresponse()
            data = response.read()
            kept = [(name.lower(), value) for name, value in response.getheaders()
                    if name.lower() not in HOP_BY_HOP and name.lower() != "content-length"]
            if method == "POST" and path == "/__benchmark/profile" and response.status == 200:
                self.profile = json.loads(data).get("profile", self.profile)
            return response.status, kept, data
        finally:
            connection.close()

    async def serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # The TLS handshake is done; charge the simulated TCP and TLS round trips.
        await asyncio.sleep(2 * self.rtt())
        conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
        conn.initiate_connection()
        writer.write(conn.data_to_send())
        streams: dict[int, tuple[list[tuple[str, str]], bytearray]] = {}
        tasks: set[asyncio.Task[None]] = set()

        async def respond(stream_id: int) -> None:
            headers, body = streams.pop(stream_id)
            fields = dict(headers)
            try:
                status, kept, data = await asyncio.to_thread(
                    self.forward, fields.get(":method", "GET"), fields.get(":path", "/"), headers, bytes(body))
            except OSError:
                status, kept, data = 502, [("content-type", "application/json")], b'{"error":{"code":"upstream","message":"Fixture unavailable."}}'
            try:
                conn.send_headers(stream_id, [(":status", str(status)), *kept, ("content-length", str(len(data)))])
                size = conn.max_outbound_frame_size
                for offset in range(0, max(len(data), 1), size):
                    chunk = data[offset:offset + size]
                    conn.send_data(stream_id, chunk, end_stream=offset + size >= len(data))
                writer.write(conn.data_to_send())
                await writer.drain()
            except (h2.exceptions.StreamClosedError, ConnectionError):
                pass

        try:
            while data := await reader.read(65_535):
                for event in conn.receive_data(data):
                    if isinstance(event, h2.events.RequestReceived):
                        streams[event.stream_id] = (list(event.headers), bytearray())
                    elif isinstance(event, h2.events.DataReceived):
                        if event.stream_id in streams:
                            streams[event.stream_id][1].extend(event.data)
                        conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, h2.events.StreamEnded) and event.stream_id in streams:
                        task = asyncio.create_task(respond(event.stream_id))
                        tasks.add(task)
                        task.add_done_callback(tasks.discard)
                    elif isinstance(event, h2.events.StreamReset):
                        streams.pop(event.stream_id, None)
                writer.write(conn.data_to_send())
                await writer.drain()
        except (ConnectionError, ssl.SSLError, h2.exceptions.ProtocolError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            writer.close()


async def main() -> None:
    parser = argparse.ArgumentParser(description="Loopback-only HTTP/2 front end for scripts/startup-fixture.py.")
    parser.add_argument("--cert", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--port", type=int, default=9443)
    parser.add_argument("--upstream", type=int, default=9444, help="Port of startup-fixture.py --plain.")
    parser.add_argument("--profile", default="instant", help="The fixture's starting profile; later changes are followed.")
    args = parser.parse_args()
    front = FrontEnd(args.upstream, args.profile)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=str(args.cert), keyfile=str(args.key))
    context.set_alpn_protocols(["h2"])
    server = await asyncio.start_server(front.serve, HOST, args.port, ssl=context)
    print(f"Synthetic Volta startup fixture over HTTP/2: https://{HOST}:{args.port} -> http://{HOST}:{args.upstream}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
