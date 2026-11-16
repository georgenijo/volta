#!/usr/bin/env python3
"""Tests port-keeper.py against fake UPnP routers served on loopback."""
import http.server
import importlib.util
import pathlib
import re
import socket
import threading
import unittest

spec = importlib.util.spec_from_file_location("keeper", pathlib.Path(__file__).with_name("port-keeper.py"))
keeper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keeper)
LOGS = []
keeper.log = LOGS.append

V1 = "urn:schemas-upnp-org:service:WANIPConnection:1"
BIND, OTHER = "192.0.2.20", "192.0.2.30"


def description(control="/random-path/ctl/IPConn", base=""):
    # Namespaced like real routers, with an unrelated service listed first.
    return (f'<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0">{base}<device><serviceList>'
            '<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>'
            '<controlURL>/l3f</controlURL></service>'
            f'<service><serviceType>{V1}</serviceType><controlURL>{control}</controlURL></service>'
            '</serviceList></device></root>')


def fault(code):
    return 500, ('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail>'
                 f'<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>{code}</errorCode>'
                 '</UPnPError></detail></s:Fault></s:Body></s:Envelope>')


class Router(http.server.BaseHTTPRequestHandler):
    """One fake router; state lives on the class and is reset per test."""

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        state = self.server.state
        self.reply(*((200, state["description"]) if self.path == state["description_path"] else (404, "")))

    def do_POST(self):
        state = self.server.state
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        action = self.headers["SOAPAction"].strip('"').split("#")[1]
        get = lambda k: re.search(rf"<{k}>(.*?)</{k}>", body).group(1)
        state["calls"].append((self.path, action, body))
        if self.path != state["control_path"]:
            return self.reply(404, "")
        key = (get("NewExternalPort"), get("NewProtocol"))
        if action == "GetSpecificPortMappingEntry":
            if state["lookup_fault"]:
                return self.reply(*state["lookup_fault"])
            if key not in state["mappings"]:
                return self.reply(*fault(714))
            m = state["mappings"][key]
            return self.reply(200, '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
                                   f'<u:R xmlns:u="{V1}"><NewInternalPort>{m["port"]}</NewInternalPort>'
                                   f'<NewInternalClient>{m["client"]}</NewInternalClient><NewEnabled>{m["enabled"]}</NewEnabled>'
                                   f'<NewLeaseDuration>{m["lease"]}</NewLeaseDuration></u:R></s:Body></s:Envelope>')
        if action == "AddPortMapping":
            if state["refuse_add"]:
                return self.reply(*fault(state["refuse_add"]))
            if state["timed_only"] and get("NewLeaseDuration") == "0":
                return self.reply(*fault(402))
            state["mappings"][key] = {"client": get("NewInternalClient"), "port": get("NewInternalPort"),
                                      "enabled": get("NewEnabled"), "lease": get("NewLeaseDuration")}
            return self.reply(200, "<r/>")
        self.reply(*fault(401))


def start(state):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Router)
    server.state = state
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def fresh(**changes):
    state = {"mappings": {}, "calls": [], "lookup_fault": None, "refuse_add": None, "timed_only": False,
             "description_path": "/random-path/rootDesc.xml", "control_path": "/random-path/ctl/IPConn",
             "description": description()}
    state.update(changes)
    return state


class PortKeeperTest(unittest.TestCase):
    def setUp(self):
        LOGS.clear()
        self.state = fresh()
        self.server = start(self.state)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.location = self.base + "/random-path/rootDesc.xml"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def service(self):
        return keeper.control(self.location)

    def adds(self):
        return [call for call in self.state["calls"] if call[1] == "AddPortMapping"]

    def test_finds_the_wan_service_at_whatever_path_the_router_uses(self):
        self.assertEqual(self.service(), (V1, self.base + "/random-path/ctl/IPConn"))

    def test_resolves_a_relative_control_url_against_url_base(self):
        self.state["description"] = description("ctl/IPConn", f"<URLBase>{self.base}/other/</URLBase>")
        self.assertEqual(self.service(), (V1, self.base + "/other/ctl/IPConn"))

    def test_adds_a_missing_mapping_as_permanent(self):
        self.assertEqual(keeper.keep(self.service(), BIND), 0)
        self.assertEqual(self.state["mappings"][("443", "TCP")]["client"], BIND)
        self.assertEqual(self.state["mappings"][("443", "TCP")]["port"], "8448")
        self.assertIn("<NewLeaseDuration>0</NewLeaseDuration>", self.adds()[-1][2])

    def test_leaves_a_healthy_mapping_alone(self):
        self.state["mappings"][("443", "TCP")] = {"client": BIND, "port": "8448", "enabled": "1", "lease": "0"}
        self.assertEqual(keeper.keep(self.service(), BIND), 0)
        self.assertEqual(self.adds(), [])

    def test_never_replaces_another_hosts_or_ports_mapping(self):
        for client, port in ((OTHER, "8448"), (BIND, "22")):
            self.state["mappings"][("443", "TCP")] = {"client": client, "port": port, "enabled": "1", "lease": "0"}
            self.assertEqual(keeper.keep(self.service(), BIND), 1)
            self.assertEqual(self.state["mappings"][("443", "TCP")]["client"], client)
        self.assertEqual(self.adds(), [])

    def test_an_unclear_lookup_failure_adds_nothing(self):
        for failure in ((500, "<html>busy</html>"), fault(501)):
            self.state["lookup_fault"] = failure
            with self.assertRaises(keeper.Refused):
                keeper.keep(self.service(), BIND)
        self.assertEqual(self.adds(), [])

    def test_enables_a_disabled_mapping(self):
        self.state["mappings"][("443", "TCP")] = {"client": BIND, "port": "8448", "enabled": "0", "lease": "0"}
        self.assertEqual(keeper.keep(self.service(), BIND), 0)
        self.assertEqual(self.state["mappings"][("443", "TCP")]["enabled"], "1")

    def test_renews_a_timed_mapping_before_it_expires(self):
        self.state["mappings"][("443", "TCP")] = {"client": BIND, "port": "8448", "enabled": "1", "lease": "3000"}
        self.assertEqual(keeper.keep(self.service(), BIND), 0)
        self.assertEqual(self.adds(), [])
        self.state["mappings"][("443", "TCP")]["lease"] = "600"
        self.assertEqual(keeper.keep(self.service(), BIND), 0)
        self.assertEqual(self.state["mappings"][("443", "TCP")]["lease"], "3600")

    def test_falls_back_to_a_timed_lease_when_permanent_is_refused(self):
        self.state["timed_only"] = True
        self.assertEqual(keeper.keep(self.service(), BIND), 0)
        self.assertIn("<NewLeaseDuration>3600</NewLeaseDuration>", self.adds()[-1][2])

    def test_a_conflict_on_add_is_refused_and_not_retried(self):
        self.state["refuse_add"] = 718
        with self.assertRaisesRegex(keeper.Refused, "error 718"):
            keeper.keep(self.service(), BIND)
        self.assertEqual(len(self.adds()), 1)

    def test_main_moves_past_a_router_that_refuses_the_add(self):
        refusing = fresh(refuse_add=501)
        first = start(refusing)
        try:
            keeper.discover = lambda bind: [f"http://127.0.0.1:{first.server_port}/random-path/rootDesc.xml", self.location]
            self.assertEqual(keeper.main({"TELEMETRY_RECEIVER_BIND": BIND}), 0)
            self.assertEqual(refusing["mappings"], {})
            self.assertIn(("443", "TCP"), self.state["mappings"])
        finally:
            first.shutdown()
            first.server_close()

    def test_main_stops_at_a_mapping_that_points_elsewhere(self):
        self.state["mappings"][("443", "TCP")] = {"client": OTHER, "port": "8448", "enabled": "1", "lease": "0"}
        later = fresh()
        second = start(later)
        try:
            keeper.discover = lambda bind: [self.location, f"http://127.0.0.1:{second.server_port}/random-path/rootDesc.xml"]
            self.assertEqual(keeper.main({"TELEMETRY_RECEIVER_BIND": BIND}), 1)
            self.assertEqual(later["calls"], [])
        finally:
            second.shutdown()
            second.server_close()

    def test_main_skips_a_stale_responder_and_uses_the_working_router(self):
        stale = start(fresh(description_path="/old/rootDesc.xml"))
        try:
            keeper.discover = lambda bind: [f"http://127.0.0.1:{stale.server_port}/gone/rootDesc.xml", self.location]
            self.assertEqual(keeper.main({"TELEMETRY_RECEIVER_BIND": BIND}), 0)
            self.assertIn(("443", "TCP"), self.state["mappings"])
        finally:
            stale.shutdown()
            stale.server_close()

    def test_main_reports_when_no_router_answers(self):
        keeper.discover = lambda bind: []
        self.assertEqual(keeper.main({"TELEMETRY_RECEIVER_BIND": BIND}), 1)

    def test_discover_keeps_distinct_self_describing_answers(self):
        keeper.DISCOVERY_WINDOW = 0.5
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as responder:
            responder.bind(("127.0.0.1", 0))

            def answer():
                _, sender = responder.recvfrom(2048)
                for location in ("http://127.0.0.1:5000/a.xml", "http://127.0.0.1:5000/a.xml",
                                 "http://192.0.2.9:5000/spoofed.xml", "https://127.0.0.1/b.xml", None,
                                 "http://127.0.0.1:5001/c.xml"):
                    header = f"LOCATION: {location}\r\n" if location else ""
                    responder.sendto(f"HTTP/1.1 200 OK\r\n{header}\r\n".encode(), sender)

            threading.Thread(target=answer, daemon=True).start()
            found = keeper.discover("127.0.0.1", ssdp=responder.getsockname())
        self.assertEqual(found, ["http://127.0.0.1:5000/a.xml", "http://127.0.0.1:5001/c.xml"])

    def test_settings_require_a_concrete_private_lan_address(self):
        for bad in ("", "0.0.0.0", "127.0.0.1", "169.254.1.1", "8.8.8.8", "not-an-ip"):
            with self.assertRaises(SystemExit) as stop:
                keeper.settings({"TELEMETRY_RECEIVER_BIND": bad})
            self.assertEqual(stop.exception.code, 2)
        self.assertEqual(keeper.settings({"TELEMETRY_RECEIVER_BIND": BIND}), BIND)

    def test_ports_are_fixed_to_the_authorized_forward(self):
        self.assertEqual((keeper.PUBLIC_PORT, keeper.RECEIVER_PORT), (443, 8448))


if __name__ == "__main__":
    unittest.main()
