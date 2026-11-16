#!/usr/bin/env python3
"""Keeps the router's port forward to the Fleet Telemetry receiver in place.

The vehicle reaches the receiver through one router forward: external TCP 443
to the receiver's LAN address on port 8448. Routers drop UPnP mappings when
they restart, and a lost forward silently stops all telemetry. A systemd timer
runs this script every few minutes; it finds the router with SSDP, checks the
mapping and adds it when it is missing.

It never replaces a mapping that points somewhere else: that is reported and
the script exits non-zero, so the timer's failure shows in `systemctl`.

Settings come from the environment (the telemetry env file in production):
  TELEMETRY_RECEIVER_BIND  LAN address the receiver listens on (required)
  TELEMETRY_PUBLIC_PORT    external port, default 443
  TELEMETRY_RECEIVER_PORT  receiver port, default 8448
Exit status: 0 mapping present or added, 1 conflict or router refused, 2 setup.
Uses only the standard library.
"""
import ipaddress
import os
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from xml.sax.saxutils import escape

DESCRIPTION = "volta-telemetry"
SERVICE_TYPES = ("urn:schemas-upnp-org:service:WANIPConnection:1",
                 "urn:schemas-upnp-org:service:WANIPConnection:2",
                 "urn:schemas-upnp-org:service:WANPPPConnection:1")
TIMEOUT = 5


def log(message):
    print(f"port-keeper: {message}", flush=True)


def settings(env):
    try:
        bind = str(ipaddress.IPv4Address(env.get("TELEMETRY_RECEIVER_BIND", "").strip()))
    except ValueError:
        raise SystemExit(log("TELEMETRY_RECEIVER_BIND must be the receiver's LAN IPv4 address") or 2)
    if ipaddress.IPv4Address(bind).is_loopback or not ipaddress.IPv4Address(bind).is_private:
        raise SystemExit(log("TELEMETRY_RECEIVER_BIND must be a private LAN address") or 2)
    ports = []
    for key, default in (("TELEMETRY_PUBLIC_PORT", "443"), ("TELEMETRY_RECEIVER_PORT", "8448")):
        value = env.get(key, default).strip()
        if not value.isdigit() or not 0 < int(value) < 65536:
            raise SystemExit(log(f"{key} must be a port number") or 2)
        ports.append(int(value))
    return bind, ports[0], ports[1]


def discover(bind, ssdp=("239.255.255.250", 1900)):
    """Returns the router's description URL, asking only from the receiver's interface."""
    message = "\r\n".join(["M-SEARCH * HTTP/1.1", f"HOST: {ssdp[0]}:{ssdp[1]}", 'MAN: "ssdp:discover"', "MX: 2",
                           "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1", "", ""]).encode()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(TIMEOUT)
        sock.bind((bind, 0))
        sock.sendto(message, ssdp)
        try:
            while True:
                data, _ = sock.recvfrom(4096)
                found = re.search(rb"(?im)^location:\s*(\S+)", data)
                if found:
                    return found.group(1).decode()
        except socket.timeout:
            return None


def control(location):
    """Finds the WAN connection service's type and control URL in the description."""
    with urllib.request.urlopen(location, timeout=TIMEOUT) as response:
        description = response.read().decode(errors="replace")
    for block in re.findall(r"<service>(.*?)</service>", description, re.S):
        kind = re.search(r"<serviceType>\s*(.*?)\s*</serviceType>", block)
        url = re.search(r"<controlURL>\s*(.*?)\s*</controlURL>", block)
        if kind and url and kind.group(1) in SERVICE_TYPES:
            return kind.group(1), urllib.parse.urljoin(location, url.group(1))
    return None


def soap(service, action, arguments):
    kind, url = service
    fields = "".join(f"<{k}>{escape(str(v))}</{k}>" for k, v in arguments)
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{kind}">{fields}</u:{action}></s:Body></s:Envelope>').encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": 'text/xml; charset="utf-8"',
                                                              "SOAPAction": f'"{kind}#{action}"'})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return 200, response.read().decode(errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")


def value(text, name):
    found = re.search(rf"<{name}>\s*(.*?)\s*</{name}>", text, re.S)
    return found.group(1) if found else None


def keep(service, bind, public, internal):
    entry = [("NewRemoteHost", ""), ("NewExternalPort", public), ("NewProtocol", "TCP")]
    status, reply = soap(service, "GetSpecificPortMappingEntry", entry)
    if status == 200:
        client, port = value(reply, "NewInternalClient"), value(reply, "NewInternalPort")
        if client == bind and port == str(internal):
            log(f"ok: TCP {public} -> receiver port {internal}")
            return 0
        log(f"conflict: TCP {public} is already mapped to another host or port; not replacing it")
        return 1
    if value(reply, "errorCode") not in ("714", None):
        log(f"router refused the lookup (error {value(reply, 'errorCode')})")
        return 1
    # Permanent first; some routers accept only timed leases. The timer renews
    # well inside an hour either way. 718 is a conflicting mapping: never retried.
    for lease in (0, 3600):
        status, reply = soap(service, "AddPortMapping", entry + [
            ("NewInternalPort", internal), ("NewInternalClient", bind), ("NewEnabled", 1),
            ("NewPortMappingDescription", DESCRIPTION), ("NewLeaseDuration", lease)])
        if status == 200:
            log(f"added: TCP {public} -> receiver port {internal} (lease {lease or 'permanent'})")
            return 0
        if value(reply, "errorCode") == "718":
            break
    log(f"router refused the mapping (error {value(reply, 'errorCode')})")
    return 1


def main(env=os.environ):
    bind, public, internal = settings(env)
    location = discover(bind)
    if not location:
        log("no UPnP router answered; is UPnP enabled on the router?")
        return 1
    try:
        service = control(location)
    except (OSError, ValueError) as error:
        log(f"cannot read the router's description: {type(error).__name__}")
        return 1
    if not service:
        log("the router offers no WAN connection service")
        return 1
    try:
        return keep(service, bind, public, internal)
    except OSError as error:
        log(f"router request failed: {type(error).__name__}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
