#!/usr/bin/env python3
"""Serve a local, synthetic HTTPS Volta API for startup-latency benchmarks.

This server is intentionally narrow: it exercises the unmodified production
``APIDataSource`` with decodable synthetic responses, never contacts a network
service, and binds only to 127.0.0.1.  The named latency profiles are controlled
SIMULATED delays for repeatable benchmark scenarios, not measured production
values.  ``observed-server`` replays fixed targets selected from a small route
timing sample; that sample excludes network transit and is not a general
production-latency claim.

Launch with caller-provided development certificate and key, for example:

    python3 scripts/startup-fixture.py --cert /path/to/localhost-cert.pem \
        --key /path/to/localhost-key.pem --profile representative --log /tmp/volta-startup.jsonl

The server listens at https://127.0.0.1:9443 by default.  POST a small JSON
object such as {"profile":"slow-history"} to
https://127.0.0.1:9443/__benchmark/profile to change scenario.  POST
/__benchmark/reset to write a run-reset record to the JSONL log.  These
localhost-only controls are for a benchmark driver, not for the Volta app.
"""

from __future__ import annotations

import argparse
import json
import logging
import ssl
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


HOST = "127.0.0.1"
DEFAULT_PORT = 9443
MAX_PATH_LENGTH = 2_048
MAX_BODY_BYTES = 4_096
VEHICLE_ID = 1
SYNTHETIC_TOKEN = "synthetic-benchmark-token"

# Controlled simulated latency in milliseconds.  These are deliberately not
# measurements of Volta, TeslaMate, Tesla, or any production infrastructure.
PROFILE_LATENCIES: dict[str, dict[str, int]] = {
    "instant": {},
    "representative": {
        "vehicles": 250, "status": 300, "timeline": 1_000,
        "today": 1_200, "week": 1_800, "month": 2_500,
    },
    "slow-history": {
        "vehicles": 250, "status": 300, "timeline": 4_000,
        "today": 4_000, "week": 5_000, "month": 6_000,
    },
    # Fixed replay targets selected from a small production route-timing sample:
    # /vehicles median 20 ms (n=4, max 31), /status 29 ms (n=2, max 38),
    # /timeline 14.5 ms (n=2, max 17), /summary 4188.5 ms (n=6, max 4238),
    # and /tesla/status 15 ms. The observed sample excludes transit. These
    # remain controlled simulated delays, not general production measurements
    # or latency predictions.
    "observed-server": {
        "vehicles": 20, "status": 29, "timeline": 15,
        "today": 4_189, "week": 4_189, "month": 4_189, "tesla": 15,
    },
    # A deterministic partial-load scenario: primary vehicle data succeeds,
    # while timeline and summaries answer 503 after representative delays.
    "history-failure": {
        "vehicles": 250, "status": 300, "timeline": 1_000,
        "today": 1_200, "week": 1_800, "month": 2_500,
    },
}
HISTORY_KEYS = frozenset(("timeline", "today", "week", "month"))


def iso8601(value: datetime) -> str:
    """Return a Swift ``ISO8601FormatStyle``-compatible UTC timestamp."""
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def current_utc() -> datetime:
    return datetime.now(timezone.utc)


def date_in_timezone(value: datetime, name: str) -> tuple[datetime, ZoneInfo]:
    """Resolve an IANA zone and convert ``value``; caller maps invalid input to 400."""
    return value.astimezone(ZoneInfo(name)), ZoneInfo(name)


def synthetic_device(now: datetime) -> dict[str, Any]:
    return {
        "id": 1,
        "name": "Synthetic Benchmark Device",
        "createdAt": iso8601(now),
        "lastSeenAt": iso8601(now),
    }


def synthetic_vehicle() -> dict[str, Any]:
    return {
        "id": VEHICLE_ID,
        "name": "Friday",
        "model": "Model Y",
        "trim": "Long Range AWD",
        "exteriorColor": "Synthetic Silver",
        "vinSuffix": "DEMO01",
        "firmware": "2026.32.6",
        "hasData": True,
    }


def synthetic_status(now: datetime) -> dict[str, Any]:
    """A stable, parked (online + disconnected) 72% Bay Area fixture."""
    return {
        "vehicleId": VEHICLE_ID,
        "state": "online",
        "updatedAt": iso8601(now),
        "batteryLevel": 72,
        "usableBatteryLevel": 71,
        "ratedRangeKm": 354.0,
        "estRangeKm": 328.0,
        "chargeLimit": 80,
        "chargingState": "disconnected",
        "chargerPowerKw": None,
        "minutesToFull": None,
        "insideTempC": 21.0,
        "outsideTempC": 16.0,
        "climateOn": False,
        "driverTempSettingC": 20.0,
        "locked": True,
        "sentryMode": False,
        "odometerKm": 38_642.0,
        "location": {
            "latitude": 37.4419,
            "longitude": -122.1430,
            "heading": 115.0,
            "address": "Synthetic Bay Area, CA",
            "placeName": "Synthetic Home",
        },
        "firmware": "2026.32.6",
        "packTempMaxC": 38.0,
        "packTempMinC": 31.0,
        "energyRemainingKwh": 43.2,
        "chargePortDoorOpen": False,
        "chargePortLatch": "ChargePortLatchEngaged",
        "tpms": {
            corner: {"pressureBar": pressure, "updatedAt": iso8601(now - timedelta(hours=1))}
            for corner, pressure in (("fl", 2.9), ("fr", 2.9), ("rl", 2.8), ("rr", 2.8))
        },
        "telemetryFreshness": {
            "connected": True,
            "lastSeenAt": iso8601(now),
            "recordedAt": {"state": iso8601(now), "batteryLevel": iso8601(now)},
        },
        "chargeEnergyAddedKwh": None,
        "chargerVoltage": None,
        "chargerCurrentA": None,
        "fastCharger": False,
        "chargeCableType": None,
        "chargeStartedAt": None,
        "chargeStartObserved": None,
        "activeChargeId": None,
        "chargeReadyAt": None,
    }


def summary_for(range_name: str, now: datetime, zone_name: str) -> dict[str, Any]:
    """Return an ActivitySummary; today starts at midnight in the requested zone."""
    local_now, zone = date_in_timezone(now, zone_name)
    if range_name == "today":
        start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
        values = (18.6, 1, 0, 3.1, 167.0, None, None)
    elif range_name == "7d":
        start = local_now - timedelta(days=7)
        values = (126.4, 6, 2, 20.7, 164.0, 35.8, 11.09)
    elif range_name == "30d":
        start = local_now - timedelta(days=30)
        values = (486.2, 22, 8, 79.7, 164.0, 142.4, 42.76)
    else:  # Kept internal; request routing validates before calling.
        raise ValueError("unsupported summary range")
    distance, drives, charges, used, efficiency, added, cost = values
    return {
        "range": range_name,
        "distanceKm": distance,
        "driveCount": drives,
        "chargeCount": charges,
        "energyUsedKwh": used,
        "efficiencyWhPerKm": efficiency,
        "energyAddedKwh": added,
        "chargeCost": cost,
        "currency": "USD",
        "periodStart": iso8601(start.astimezone(timezone.utc)),
        "periodEnd": iso8601(now),
        "timeZone": zone.key,
    }


def synthetic_timeline(now: datetime, hours: int) -> list[dict[str, Any]]:
    """Return recent, non-overlapping timeline segments in Volta's API shape."""
    hours = max(1, min(hours, 744))
    start = now - timedelta(hours=hours)
    drive_start = max(start, now - timedelta(hours=2, minutes=20))
    drive_end = now - timedelta(hours=1, minutes=50)
    idle_end = now - timedelta(minutes=40)
    return [
        {"kind": "asleep", "start": iso8601(start), "end": iso8601(drive_start)},
        {"kind": "drive", "start": iso8601(drive_start), "end": iso8601(drive_end)},
        {"kind": "idle", "start": iso8601(drive_end), "end": iso8601(idle_end)},
        {"kind": "asleep", "start": iso8601(idle_end), "end": iso8601(now)},
    ]


def synthetic_drive(now: datetime) -> dict[str, Any]:
    start = now - timedelta(hours=2, minutes=20)
    end = now - timedelta(hours=1, minutes=50)
    return {
        "id": 101,
        "start": iso8601(start), "end": iso8601(end),
        "startAddress": "Synthetic Bay Area, CA", "endAddress": "Synthetic Bay Area, CA",
        "distanceKm": 18.6, "durationMin": 30.0,
        "startBatteryLevel": 76, "endBatteryLevel": 72,
        "energyUsedKwh": 3.1, "efficiencyWhPerKm": 167.0,
        "maxSpeedKph": 91.0, "avgSpeedKph": 37.2, "outsideTempAvgC": 16.0,
        "startCity": "Synthetic Bay Area", "endCity": "Synthetic Bay Area",
        "ratedWhPerKm": 164.0, "energySource": "synthetic_fixture",
    }


def synthetic_charge(now: datetime) -> dict[str, Any]:
    start = now - timedelta(days=2, hours=3)
    end = start + timedelta(minutes=45)
    return {
        "id": 201,
        "start": iso8601(start), "end": iso8601(end),
        "address": "Synthetic Bay Area, CA", "placeName": "Synthetic Charger",
        "energyAddedKwh": 24.0, "energyUsedKwh": 26.1,
        "startBatteryLevel": 38, "endBatteryLevel": 72,
        "durationMin": 45.0, "maxPowerKw": 11.0, "fastCharger": False,
        "cost": 6.00, "currency": "USD", "outsideTempAvgC": 16.0,
        "latitude": 37.4148, "longitude": -122.0782, "source": "synthetic_fixture",
        "avgPowerKw": 10.7, "city": "Synthetic Bay Area", "street": "Synthetic Way",
        "energyFromGridKwh": 26.1,
    }


class BenchmarkState:
    """Thread-safe mutable profile selection and bounded JSONL event sink."""

    def __init__(self, profile: str, log_path: Path | None) -> None:
        self._profile = profile
        self._log_path = log_path
        self._lock = threading.Lock()

    def profile(self) -> str:
        with self._lock:
            return self._profile

    def set_profile(self, profile: str) -> None:
        if profile not in PROFILE_LATENCIES:
            raise ValueError("unknown latency profile")
        with self._lock:
            self._profile = profile

    def log(self, event: dict[str, Any]) -> None:
        """Append one compact event; request headers and bodies are never logged."""
        if self._log_path is None:
            return
        encoded = json.dumps(event, separators=(",", ":"), ensure_ascii=True)
        with self._lock:
            with self._log_path.open("a", encoding="utf-8") as handle:
                handle.write(encoded + "\n")


class FixtureServer(ThreadingHTTPServer):
    """Threading HTTP server carrying only the small benchmark state object."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], state: BenchmarkState, context: ssl.SSLContext) -> None:
        super().__init__(address, FixtureHandler)
        self.state = state
        self.context = context

    def finish_request(self, request: Any, client_address: Any) -> None:
        # URLSession opens speculative connections. Handshake on this client's
        # worker, never on the accept loop where it could block every request.
        try:
            request.settimeout(30)
            with self.context.wrap_socket(request, server_side=True) as secure:
                self.RequestHandlerClass(secure, client_address, self)
        except (OSError, ssl.SSLError):
            pass


class FixtureHandler(BaseHTTPRequestHandler):
    """Volta API subset; deliberately ignores auth and never records request data."""

    protocol_version = "HTTP/1.1"
    server_version = "VoltaStartupFixture/1.0"
    sys_version = ""

    @property
    def state(self) -> BenchmarkState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, _format: str, *_args: object) -> None:
        # BaseHTTPRequestHandler otherwise writes request lines to stderr.
        return

    def do_GET(self) -> None:  # noqa: N802 - stdlib HTTP handler contract
        self._handle()

    def do_POST(self) -> None:  # noqa: N802 - stdlib HTTP handler contract
        self._handle()

    def do_DELETE(self) -> None:  # noqa: N802 - stdlib HTTP handler contract
        self._handle()

    def _handle(self) -> None:
        started_wall = current_utc()
        started_mono = time.perf_counter()
        parsed = urlsplit(self.path)
        path = parsed.path
        status = HTTPStatus.INTERNAL_SERVER_ERROR
        try:
            if len(self.path) > MAX_PATH_LENGTH:
                status = HTTPStatus.REQUEST_URI_TOO_LONG
                self._send_json(status, error_payload("request_too_long", "Request path is too long."))
                return
            if self.command == "POST" and path.startswith("/__benchmark/"):
                status = self._control(path)
                return
            if path.startswith("/__benchmark/"):
                status = HTTPStatus.METHOD_NOT_ALLOWED
                self._send_json(status, error_payload("method_not_allowed", "POST is required."))
                return
            status = self._api(path, parse_qs(parsed.query, keep_blank_values=True))
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            # Benchmark clients may cancel deliberately; do not turn that into a traceback.
            return
        except Exception:
            logging.exception("synthetic fixture request failed")
            status = HTTPStatus.SERVICE_UNAVAILABLE
            self._safe_send_json(status, error_payload("service_unavailable", "Synthetic fixture failed."))
        finally:
            ended_wall = current_utc()
            elapsed_ms = round((time.perf_counter() - started_mono) * 1_000, 3)
            # Parsed path only: never query string, headers, or request body.
            self.state.log({
                "event": "request", "path": path[:MAX_PATH_LENGTH],
                "start": iso8601(started_wall), "end": iso8601(ended_wall),
                "elapsedMs": elapsed_ms, "status": int(status),
            })

    def _api(self, path: str, query: dict[str, list[str]]) -> HTTPStatus:
        now = current_utc()
        if self.command == "POST" and path == "/v1/auth/pair":
            # Consume without logging so a keep-alive connection can be reused.
            self._discard_body()
            self._delay("pair")
            return self._send_json(HTTPStatus.OK, {"token": SYNTHETIC_TOKEN, "device": synthetic_device(now)})
        if self.command == "GET" and path == "/v1/health":
            return self._send_json(HTTPStatus.OK, {"ok": True, "version": "synthetic-startup-fixture", "teslamate": {"reachable": True, "lastDataAt": iso8601(now)}})
        if self.command == "GET" and path == "/v1/me":
            return self._send_json(HTTPStatus.OK, synthetic_device(now))
        if self.command == "DELETE" and path == "/v1/me":
            return self._send_empty(HTTPStatus.NO_CONTENT)
        if self.command != "GET":
            return self._send_json(HTTPStatus.METHOD_NOT_ALLOWED, error_payload("method_not_allowed", "Unsupported method."))
        if path == "/v1/vehicles":
            self._delay("vehicles")
            return self._send_json(HTTPStatus.OK, [synthetic_vehicle()])
        if path == "/v1/tesla/status":
            self._delay("tesla")
            return self._send_json(HTTPStatus.OK, tesla_status())

        parts = path.strip("/").split("/")
        if parts[:2] == ["v1", "vehicles"] and len(parts) >= 4 and parts[2] == str(VEHICLE_ID):
            endpoint = parts[3]
            if endpoint == "status" and len(parts) == 4:
                self._delay("status")
                return self._send_json(HTTPStatus.OK, synthetic_status(now))
            if endpoint == "summary" and len(parts) == 4:
                range_name = query.get("range", ["today"])[0]
                latency_key = {"today": "today", "7d": "week", "30d": "month"}.get(range_name)
                if latency_key is None:
                    return self._send_json(HTTPStatus.BAD_REQUEST, error_payload("invalid_range", "range must be today, 7d, or 30d."))
                zone_name = query.get("tz", ["UTC"])[0] or "UTC"
                try:
                    self._delay(latency_key)
                    if self.state.profile() == "history-failure":
                        return self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, error_payload("history_unavailable", "Synthetic history failure profile."))
                    return self._send_json(HTTPStatus.OK, summary_for(range_name, now, zone_name))
                except ZoneInfoNotFoundError:
                    return self._send_json(HTTPStatus.BAD_REQUEST, error_payload("invalid_time_zone", "tz must be an IANA time zone."))
            if endpoint == "timeline" and len(parts) == 4:
                try:
                    hours = int(query.get("hours", ["48"])[0])
                except ValueError:
                    return self._send_json(HTTPStatus.BAD_REQUEST, error_payload("invalid_hours", "hours must be an integer."))
                if not 1 <= hours <= 744:
                    return self._send_json(HTTPStatus.BAD_REQUEST, error_payload("invalid_hours", "hours must be from 1 through 744."))
                self._delay("timeline")
                if self.state.profile() == "history-failure":
                    return self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, error_payload("history_unavailable", "Synthetic history failure profile."))
                return self._send_json(HTTPStatus.OK, synthetic_timeline(now, hours))
            if endpoint == "drives" and len(parts) == 4:
                return self._send_json(HTTPStatus.OK, {"items": [synthetic_drive(now)], "nextCursor": None})
            if endpoint == "charges" and len(parts) == 4:
                return self._send_json(HTTPStatus.OK, {"items": [synthetic_charge(now)], "nextCursor": None})
        if parts[:2] == ["v1", "drives"] and len(parts) == 3 and parts[2] == "101":
            drive = synthetic_drive(now)
            drive.update({"path": [], "elevationGainM": None, "elevationLossM": None, "charts": None})
            return self._send_json(HTTPStatus.OK, drive)
        if parts[:2] == ["v1", "charges"] and len(parts) == 3 and parts[2] == "201":
            charge = synthetic_charge(now)
            charge.update({"samples": [], "efficiency": None, "telemetry": None})
            return self._send_json(HTTPStatus.OK, charge)
        return self._send_json(HTTPStatus.NOT_FOUND, error_payload("not_found", "Synthetic endpoint not found."))

    def _control(self, path: str) -> HTTPStatus:
        if path == "/__benchmark/reset":
            self._discard_body()
            self.state.log({"event": "run_reset", "at": iso8601(current_utc()), "profile": self.state.profile()})
            return self._send_json(HTTPStatus.OK, {"ok": True, "profile": self.state.profile()})
        if path != "/__benchmark/profile":
            self._discard_body()
            return self._send_json(HTTPStatus.NOT_FOUND, error_payload("not_found", "Benchmark control not found."))
        body = self._read_control_json()
        if body is None:
            return self._send_json(HTTPStatus.BAD_REQUEST, error_payload("invalid_control", "Expected a small JSON object."))
        profile = body.get("profile") if isinstance(body, dict) else None
        if not isinstance(profile, str) or len(profile) > 32 or profile not in PROFILE_LATENCIES:
            return self._send_json(HTTPStatus.BAD_REQUEST, error_payload("invalid_profile", "Unknown latency profile."))
        self.state.set_profile(profile)
        return self._send_json(HTTPStatus.OK, {"ok": True, "profile": profile, "profiles": list(PROFILE_LATENCIES)})

    def _delay(self, key: str) -> None:
        delay_ms = PROFILE_LATENCIES[self.state.profile()].get(key, 0)
        if delay_ms:
            time.sleep(delay_ms / 1_000)

    def _discard_body(self) -> None:
        """Boundedly consume a body without parsing or logging its contents."""
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = MAX_BODY_BYTES + 1
        if 0 < size <= MAX_BODY_BYTES:
            self.rfile.read(size)
        elif size > MAX_BODY_BYTES or size < 0:
            self.close_connection = True

    def _read_control_json(self) -> Any | None:
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if not 0 < size <= MAX_BODY_BYTES:
            return None
        try:
            return json.loads(self.rfile.read(size).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None

    def _send_json(self, status: HTTPStatus, payload: Any) -> HTTPStatus:
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)
        return status

    def _safe_send_json(self, status: HTTPStatus, payload: Any) -> None:
        try:
            self._send_json(status, payload)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def _send_empty(self, status: HTTPStatus) -> HTTPStatus:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return status


def error_payload(code: str, message: str) -> dict[str, dict[str, str]]:
    return {"error": {"code": code, "message": message}}


def tesla_status() -> dict[str, Any]:
    """A fixed unavailable-but-well-formed TeslaLink status; no Tesla calls occur."""
    return {
        "available": False, "connected": False, "needsReauth": False, "linkPending": False,
        "collector": {"enabled": False},
        "budget": {"monthlyLimitUsd": 0.0, "spentUsd": 0.0, "paused": False},
    }


def self_validate() -> None:
    """Cheap stdlib-only schema and profile checks; does not open a socket."""
    now = current_utc()
    payloads = [
        synthetic_device(now), synthetic_vehicle(), synthetic_status(now),
        summary_for("today", now, "America/Los_Angeles"), synthetic_timeline(now, 48),
        {"items": [synthetic_drive(now)], "nextCursor": None},
        {"items": [synthetic_charge(now)], "nextCursor": None}, tesla_status(),
    ]
    for payload in payloads:
        assert json.loads(json.dumps(payload)) is not None
    today = summary_for("today", now, "America/Los_Angeles")
    assert today["range"] == "today" and today["timeZone"] == "America/Los_Angeles"
    assert set(PROFILE_LATENCIES) == {"instant", "representative", "slow-history", "observed-server", "history-failure"}
    assert PROFILE_LATENCIES["representative"]["month"] == 2_500
    assert PROFILE_LATENCIES["observed-server"] == {
        "vehicles": 20, "status": 29, "timeline": 15,
        "today": 4_189, "week": 4_189, "month": 4_189, "tesla": 15,
    }
    print("startup-fixture self-validation passed")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=("Synthetic localhost HTTPS Volta startup-fixture server. Profile delays are controlled simulations, "
                     "not production measurements; observed-server replays a small server-only sample that excludes transit."),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--cert", type=Path, help="Caller-provided PEM certificate for localhost HTTPS.")
    parser.add_argument("--key", type=Path, help="Caller-provided PEM private key for localhost HTTPS.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Local port (default: {DEFAULT_PORT}).")
    parser.add_argument("--profile", choices=tuple(PROFILE_LATENCIES), default="instant", help="Controlled simulated-latency profile (default: instant).")
    parser.add_argument("--log", type=Path, help="Optional JSONL request timing log; excludes headers and request bodies.")
    parser.add_argument("--self-test", action="store_true", help="Validate synthetic response shapes and profile definitions, then exit.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_validate()
        return 0
    if args.cert is None or args.key is None:
        raise SystemExit("--cert and --key are required unless --self-test is used")
    if not (1 <= args.port <= 65_535):
        raise SystemExit("--port must be between 1 and 65535")
    if not args.cert.is_file() or not args.key.is_file():
        raise SystemExit("--cert and --key must name readable files")
    state = BenchmarkState(args.profile, args.log)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=str(args.cert), keyfile=str(args.key))
    server = FixtureServer((HOST, args.port), state, context)
    print(f"Synthetic Volta startup fixture: https://{HOST}:{args.port} (profile={args.profile})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
