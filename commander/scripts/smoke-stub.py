#!/usr/bin/env python3
"""Offline local executable acceptance; synthetic fixtures only, no Tesla."""
import base64
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
GO = os.environ.get("GO", "go")


def main():
    # Don't adopt or terminate someone else's listener.
    for port in (19090, 8090, 8091, 8092):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", port))
    with tempfile.TemporaryDirectory(prefix="volta-commander-stub-") as tmp:
        tmp = Path(tmp)
        processes = []
        secret = secrets.token_urlsafe(32)
        collector = secrets.token_urlsafe(32)
        env = dict(os.environ, COMMANDER_MODE="stub", COMMANDER_COMMANDS_ENABLED="true",
                   COMMANDER_INTERNAL_SECRET=secret,
                   COMMANDER_ENCRYPTION_KEY=base64.b64encode(secrets.token_bytes(32)).decode(),
                   COMMANDER_DATA_DIR=str(tmp / "data"),
                   COMMANDER_VEHICLES='{"1":"5YJ3E1EA7KF000001"}',
                   COMMANDER_LISTEN="127.0.0.1:8090", COMMANDER_CALLBACK_LISTEN="127.0.0.1:8091",
                   COMMANDER_STUB_URL="http://127.0.0.1:19090", TESLA_CLIENT_ID="STUB_ONLY",
                   TESLA_CLIENT_SECRET="STUB_ONLY", TESLA_REDIRECT_URI="http://127.0.0.1:8091/volta/oauth/callback",
                   COMMANDER_COLLECTOR_ENABLED="true", COMMANDER_COLLECTOR_LISTEN="127.0.0.1:8092",
                   COMMANDER_COLLECTOR_SECRET=collector,
                   TESLA_PROXY_CA_FILE="", TESLA_PUBLIC_KEY_FILE="")

        def build(name):
            subprocess.run([GO, "build", "-o", str(tmp / name), f"./cmd/{name}"], cwd=ROOT, check=True)

        def start(name):
            process = subprocess.Popen([str(tmp / name)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process)
            return process

        def request(path, method="GET", body=None, key=None):
            headers = {"Authorization": f"Bearer {secret}"}
            if key:
                headers["Idempotency-Key"] = key
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request("http://127.0.0.1:8090" + path, data=data, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=5) as res:
                return json.load(res), res.headers

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                return None

        def location(url):
            try:
                urllib.request.build_opener(NoRedirect).open(url, timeout=5)
            except urllib.error.HTTPError as e:
                assert e.code == 302
                return e.headers["Location"]
            raise AssertionError("expected a redirect")

        def teslamate(path, method="GET"):
            req = urllib.request.Request("http://127.0.0.1:8092" + path, data=b"{}" if method == "POST" else None,
                                         headers={"Authorization": f"Bearer {collector}"}, method=method)
            try:
                with urllib.request.urlopen(req, timeout=5) as res:
                    return res.status, json.load(res)
            except urllib.error.HTTPError as e:
                return e.code, None

        def ready(process, url, authenticated=False):
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError("Owned fixture process exited before readiness")
                try:
                    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {secret}"} if authenticated else {})
                    with urllib.request.urlopen(req, timeout=.2):
                        return
                except OSError:
                    time.sleep(.05)
            raise RuntimeError("Owned fixture did not become ready")

        def stop(process):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

        try:
            build("fakefleet")
            build("commander")
            fake = start("fakefleet")
            ready(fake, "http://127.0.0.1:19090/api/1/users/region")
            app = start("commander")
            ready(app, "http://127.0.0.1:8090/v1/health", True)
            assert teslamate("/oauth2/v3/token", "POST")[0] == 200
            assert teslamate("/api/1/products")[1]["response"] == []
            auth, _ = request("/oauth/start", "POST", {"deviceId": "7"})
            # Tesla -> public bounce -> app callback; the app relays it privately.
            bounce = location(auth["authorizationUrl"])
            assert bounce.startswith("http://127.0.0.1:8091/volta/oauth/callback?")
            app_url = location(bounce)
            assert app_url.startswith("volta://tesla-callback?")
            query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(app_url).query))
            linked, _ = request("/oauth/complete", "POST", {"deviceId": "7", **query})
            assert linked["connected"] and not linked["needsReauth"]
            replay, _ = request("/oauth/complete", "POST", {"deviceId": "7", **query})
            assert replay == linked
            status, products = teslamate("/api/1/products")
            assert status == 200 and products["response"][0]["vin"] == "5YJ3E1EA7KF000001"
            # A second upstream read inside the budget's pacing window waits (429 + Retry-After).
            assert teslamate("/api/1/vehicles/1/vehicle_data?endpoints=charge_state%3Blocation_data")[0] == 429
            assert teslamate("/api/1/vehicles/1/wake_up", "POST")[0] == 404
            path = "/v1/vehicles/1/commands/lock"
            first, _ = request(path, "POST", {}, "offline-stub-intent-0001")
            second, headers = request(path, "POST", {}, "offline-stub-intent-0001")
            assert first == second and first["ok"] and headers["Idempotency-Replayed"] == "true"
            stop(app)
            app = start("commander")
            ready(app, "http://127.0.0.1:8090/v1/health", True)
            third, headers = request(path, "POST", {}, "offline-stub-intent-0001")
            assert third == first and headers["Idempotency-Replayed"] == "true"
            audit = (tmp / "data/audit.jsonl").read_text()
            assert audit.count('"msg":"command_started"') == 1
            assert "STUB_ACCESS_ONLY" not in audit and "STUB_REFRESH_ONLY" not in audit
            assert query["state"] not in audit and query["code"] not in audit and collector not in audit
            assert request("/oauth/account", "DELETE")[0]["ok"]
            assert not request("/v1/health")[0]["authorized"]
            print("PASS: stub device-bound sign-in via public bounce, completion replay, TeslaMate collector, "
                  "command, restart replay, audit privacy, disconnect; no Tesla requests")
        finally:
            for process in reversed(processes):
                stop(process)


if __name__ == "__main__":
    main()
