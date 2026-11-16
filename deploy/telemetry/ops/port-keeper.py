#!/usr/bin/env python3
"""Keeps the router's port forward to the Fleet Telemetry receiver in place.

The vehicle reaches the receiver through one router forward: external TCP 443
to the receiver's LAN address on port 8448. That is the only authorized public
exposure, so both ports are fixed here, not configurable. Routers drop UPnP
mappings when they restart and may serve their UPnP description at a path that
changes, and a lost forward silently stops all telemetry. A systemd timer runs
this script every few minutes. It discovers the router with SSDP, checks the
mapping, and adds or renews it when it is missing, disabled or about to expire.

It never replaces a mapping that points at another host or port, and it adds
nothing unless the router answered that no mapping exists (UPnP error 714).
Every other outcome exits non-zero, so the unit shows as failed.

Settings come from the environment (the telemetry env file in production):
  TELEMETRY_RECEIVER_BIND  the receiver's LAN IPv4 address on this node (required)
Exit status: 0 mapping in place, 1 conflict, router refusal or no router, 2 setup.
Uses only the standard library.
"""
import ipaddress
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from xml.sax.saxutils import escape

PUBLIC_PORT, RECEIVER_PORT = 443, 8448
DESCRIPTION = "volta-telemetry"
SERVICE_TYPES = ("urn:schemas-upnp-org:service:WANIPConnection:2",
                 "urn:schemas-upnp-org:service:WANIPConnection:1",
                 "urn:schemas-upnp-org:service:WANPPPConnection:1")
TIMEOUT = 5            # seconds per network operation
DISCOVERY_WINDOW = 3   # seconds to collect SSDP answers
MAX_BODY = 64 * 1024   # bytes read from any router response
MAX_ANSWERS = 16
TIMED_LEASE = 3600     # used only when the router refuses a permanent mapping
RENEW_BELOW = 1200     # renew a timed mapping with less than this many seconds left


def log(message):
    print(f"port-keeper: {message}", flush=True)


class Refused(Exception):
    """The router answered, but not in a way that allows a safe change."""


def settings(env):
    """Returns the receiver's LAN address; it must be private and concrete."""
    try:
        bind = ipaddress.IPv4Address(env.get("TELEMETRY_RECEIVER_BIND", "").strip())
    except ValueError:
        bind = None
    if bind is None or not bind.is_private or bind.is_loopback or bind.is_unspecified \
            or bind.is_link_local or bind.is_multicast:
        log("TELEMETRY_RECEIVER_BIND must be this node's private LAN IPv4 address")
        raise SystemExit(2)
    return str(bind)


def discover(bind, ssdp=("239.255.255.250", 1900)):
    """Collects distinct router description URLs answering from the receiver's LAN."""
    message = "\r\n".join(["M-SEARCH * HTTP/1.1", f"HOST: {ssdp[0]}:{ssdp[1]}", 'MAN: "ssdp:discover"', "MX: 2",
                           "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1", "", ""]).encode()
    found = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.bind((bind, 0))  # fails unless the address belongs to this node
        except OSError:
            log("TELEMETRY_RECEIVER_BIND is not an address on this node")
            raise SystemExit(2)
        # Send the search out of the receiver's interface, not whichever the route picks.
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(bind))
        sock.sendto(message, ssdp)
        deadline = time.monotonic() + DISCOVERY_WINDOW
        while len(found) < MAX_ANSWERS:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            sock.settimeout(left)
            try:
                data, (sender, _) = sock.recvfrom(2048)
            except socket.timeout:
                break
            location = re.search(rb"(?im)^location:[ \t]*(\S+)", data)
            if location:
                url = location.group(1).decode("ascii", "replace")
                parts = urllib.parse.urlsplit(url)
                # A device may only point at itself, so no LAN host can steer the keeper elsewhere.
                if parts.scheme == "http" and parts.hostname == sender and url not in found:
                    found.append(url)
    return found


def local(element):
    """An element's name without its XML namespace."""
    return element.tag.rsplit("}", 1)[-1]


def child_text(element, name):
    for child in element:
        if local(child) == name:
            return (child.text or "").strip()
    return ""


def fetch(request):
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.status, response.read(MAX_BODY)


def control(location):
    """Returns (service type, absolute control URL) of the router's WAN connection, or None."""
    _, body = fetch(location)
    root = ElementTree.fromstring(body)
    base = child_text(root, "URLBase") or location
    services = {}
    for element in root.iter():
        if local(element) == "service":
            kind, url = child_text(element, "serviceType"), child_text(element, "controlURL")
            if kind in SERVICE_TYPES and url:
                services.setdefault(kind, urllib.parse.urljoin(base, url))
    for kind in SERVICE_TYPES:
        if kind in services:
            return kind, services[kind]
    return None


def soap(service, action, arguments):
    """Returns (HTTP status, {field: text}) with the UPnP errorCode as "errorCode"."""
    kind, url = service
    fields = "".join(f"<{k}>{escape(str(v))}</{k}>" for k, v in arguments)
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{kind}">{fields}</u:{action}></s:Body></s:Envelope>').encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": 'text/xml; charset="utf-8"',
                                                              "SOAPAction": f'"{kind}#{action}"'})
    try:
        status, reply = fetch(request)
    except urllib.error.HTTPError as error:
        with error:
            status, reply = error.code, error.read(MAX_BODY)
    values = {}
    try:
        for element in ElementTree.fromstring(reply).iter():
            name = local(element)
            if element.text and element.text.strip() and name not in values:
                values[name] = element.text.strip()
    except ElementTree.ParseError:
        pass
    return status, values


def add(service, bind, entry, lease):
    return soap(service, "AddPortMapping", entry + [
        ("NewInternalPort", RECEIVER_PORT), ("NewInternalClient", bind), ("NewEnabled", 1),
        ("NewPortMappingDescription", DESCRIPTION), ("NewLeaseDuration", lease)])


def keep(service, bind):
    entry = [("NewRemoteHost", ""), ("NewExternalPort", PUBLIC_PORT), ("NewProtocol", "TCP")]
    status, found = soap(service, "GetSpecificPortMappingEntry", entry)
    if status == 200:
        if found.get("NewInternalClient") != bind or found.get("NewInternalPort") != str(RECEIVER_PORT):
            log(f"conflict: TCP {PUBLIC_PORT} is mapped to another host or port; not replacing it")
            return 1
        lease = found.get("NewLeaseDuration", "0")
        lease = int(lease) if lease.isdigit() else 0
        if found.get("NewEnabled", "1") == "1" and (lease == 0 or lease > RENEW_BELOW):
            log(f"ok: TCP {PUBLIC_PORT} -> receiver port {RECEIVER_PORT}" + (f" ({lease}s left)" if lease else ""))
            return 0
        # Same host and port: re-adding updates this mapping in place (enable or renew).
        status, reply = add(service, bind, entry, lease and TIMED_LEASE)
        if status == 200:
            log(f"renewed: TCP {PUBLIC_PORT} -> receiver port {RECEIVER_PORT}")
            return 0
        log(f"router refused the renewal (error {reply.get('errorCode', status)})")
        return 1
    if found.get("errorCode") != "714":  # only "no such entry" allows an add
        raise Refused(f"lookup failed (error {found.get('errorCode', status)})")
    # Permanent first; some routers accept only timed leases, renewed above.
    for lease in (0, TIMED_LEASE):
        status, reply = add(service, bind, entry, lease)
        if status == 200:
            log(f"added: TCP {PUBLIC_PORT} -> receiver port {RECEIVER_PORT} (lease {lease or 'permanent'})")
            return 0
        if reply.get("errorCode") == "718":  # conflicting mapping: never retried
            break
    log(f"router refused the mapping (error {reply.get('errorCode', status)})")
    return 1


def main(env=os.environ):
    bind = settings(env)
    locations = discover(bind)
    if not locations:
        log("no UPnP router answered; is UPnP enabled on the router?")
        return 1
    # Mesh satellites may answer too; use the first that offers a working WAN service.
    for location in locations:
        try:
            service = control(location)
            if service:
                return keep(service, bind)
        except Refused as error:
            log(f"{error} at one responder; trying the next")
        except (OSError, ValueError, ElementTree.ParseError) as error:
            log(f"skipping a responder: {type(error).__name__}")
    log("no responder offered a usable WAN connection service")
    return 1


if __name__ == "__main__":
    sys.exit(main())
