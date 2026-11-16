#!/usr/bin/env python3
"""Tests port-keeper.py against a fake UPnP router served on loopback."""
import http.server
import importlib.util
import pathlib
import re
import threading
import unittest

spec = importlib.util.spec_from_file_location("keeper", pathlib.Path(__file__).with_name("port-keeper.py"))
keeper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keeper)
keeper.log = lambda message: Router.logs.append(message)

KIND = "urn:schemas-upnp-org:service:WANIPConnection:1"
DESCRIPTION = f"""<root><device><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/l3f</controlURL></service>
<service><serviceType>{KIND}</serviceType><controlURL>/random-path/ctl/IPConn</controlURL></service>
</serviceList></device></root>"""


def fault(code):
    return 500, f"<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>{code}</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"


class Router(http.server.BaseHTTPRequestHandler):
    mappings, calls, logs, refuse_add, timed_only = {}, [], [], None, False

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(*((200, DESCRIPTION) if self.path == "/random-path/rootDesc.xml" else (404, "")))

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        action = self.headers["SOAPAction"].strip('"').split("#")[1]
        get = lambda k: re.search(rf"<{k}>(.*?)</{k}>", body).group(1)
        Router.calls.append((action, body))
        key = (get("NewExternalPort"), get("NewProtocol"))
        if action == "GetSpecificPortMappingEntry":
            if key not in Router.mappings:
                return self.reply(*fault(714))
            client, port = Router.mappings[key]
            return self.reply(200, f"<r><NewInternalPort>{port}</NewInternalPort><NewInternalClient>{client}</NewInternalClient></r>")
        if action == "AddPortMapping":
            if Router.refuse_add:
                return self.reply(*fault(Router.refuse_add))
            if Router.timed_only and get("NewLeaseDuration") == "0":
                return self.reply(*fault(402))
            Router.mappings[key] = (get("NewInternalClient"), get("NewInternalPort"))
            return self.reply(200, "<r/>")
        self.reply(*fault(401))


class PortKeeperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Router)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.location = f"http://127.0.0.1:{cls.server.server_port}/random-path/rootDesc.xml"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Router.mappings, Router.calls, Router.logs, Router.refuse_add, Router.timed_only = {}, [], [], None, False
        self.service = keeper.control(self.location)

    def test_finds_the_wan_service_at_whatever_path_the_router_uses(self):
        self.assertEqual(self.service, (KIND, f"http://127.0.0.1:{self.server.server_port}/random-path/ctl/IPConn"))

    def test_adds_a_missing_mapping_as_permanent(self):
        self.assertEqual(keeper.keep(self.service, "192.168.1.20", 443, 8448), 0)
        self.assertEqual(Router.mappings, {("443", "TCP"): ("192.168.1.20", "8448")})
        self.assertIn("<NewLeaseDuration>0</NewLeaseDuration>", Router.calls[-1][1])

    def test_leaves_a_correct_mapping_alone(self):
        Router.mappings[("443", "TCP")] = ("192.168.1.20", "8448")
        self.assertEqual(keeper.keep(self.service, "192.168.1.20", 443, 8448), 0)
        self.assertEqual([action for action, _ in Router.calls], ["GetSpecificPortMappingEntry"])

    def test_never_replaces_another_hosts_mapping(self):
        Router.mappings[("443", "TCP")] = ("192.168.1.30", "443")
        self.assertEqual(keeper.keep(self.service, "192.168.1.20", 443, 8448), 1)
        self.assertEqual(Router.mappings[("443", "TCP")], ("192.168.1.30", "443"))
        self.assertTrue(any("conflict" in line for line in Router.logs))

    def test_falls_back_to_a_timed_lease_when_permanent_is_refused(self):
        Router.timed_only = True
        self.assertEqual(keeper.keep(self.service, "192.168.1.20", 443, 8448), 0)
        self.assertEqual(Router.mappings, {("443", "TCP"): ("192.168.1.20", "8448")})
        self.assertIn("<NewLeaseDuration>3600</NewLeaseDuration>", Router.calls[-1][1])

    def test_a_conflict_is_reported_and_not_retried(self):
        Router.refuse_add = 718
        self.assertEqual(keeper.keep(self.service, "192.168.1.20", 443, 8448), 1)
        self.assertEqual([action for action, _ in Router.calls].count("AddPortMapping"), 1)
        self.assertTrue(any("error 718" in line for line in Router.logs))

    def test_a_router_without_the_description_fails_cleanly(self):
        with self.assertRaises(OSError):
            keeper.control(self.location.replace("random-path", "old-path"))

    def test_settings_require_a_private_lan_address(self):
        for bad in ("", "127.0.0.1", "8.8.8.8", "not-an-ip"):
            with self.assertRaises(SystemExit) as stop:
                keeper.settings({"TELEMETRY_RECEIVER_BIND": bad})
            self.assertEqual(stop.exception.code, 2)
        self.assertEqual(keeper.settings({"TELEMETRY_RECEIVER_BIND": "192.168.1.20"}), ("192.168.1.20", 443, 8448))
        with self.assertRaises(SystemExit):
            keeper.settings({"TELEMETRY_RECEIVER_BIND": "192.168.1.20", "TELEMETRY_PUBLIC_PORT": "70000"})


if __name__ == "__main__":
    unittest.main()
