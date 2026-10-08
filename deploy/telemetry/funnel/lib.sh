# Shared by stage/rollback/check. Sourced, not executed.
# The receiver's public route is the only thing these scripts touch.
FUNNEL_PORT=10000
FUNNEL_TARGET=tcp://127.0.0.1:8448
. "$(dirname "${BASH_SOURCE[0]}")/../node-host.sh"
FUNNEL_HOST="${FUNNEL_HOST:-$(node_host)}"
[[ -n $FUNNEL_HOST ]] || { echo "funnel: set FUNNEL_HOST or log in to tailscale" >&2; exit 1; }
# Serve ports that exist before staging and must survive both directions
# byte-for-byte (compared as normalized JSON).
EXPECTED_SERVE_PORTS="443 8443 8446 8447 8500 8844 8845 8879 9443"

ts() { tailscale "$@"; }

# Prints the serve status JSON with the owned port removed, normalized.
serve_without_owned() {
  ts serve status --json | python3 -c '
import json, sys
d = json.load(sys.stdin) or {}
port = sys.argv[1]
d.get("TCP", {}).pop(port, None)
for k in list(d.get("AllowFunnel", {}) or {}):
    if k.endswith(":" + port):
        d["AllowFunnel"].pop(k)
if not d.get("AllowFunnel"):
    d.pop("AllowFunnel", None)
print(json.dumps(d, sort_keys=True))
' "$FUNNEL_PORT"
}

# Prints the sorted TCP port list.
serve_ports() {
  ts serve status --json | python3 -c '
import json, sys
d = json.load(sys.stdin) or {}
print(" ".join(sorted(d.get("TCP", {}), key=int)))
'
}

# Prints "on" when the owned port is a raw TCP forward to the receiver with
# Funnel allowed, "absent" when it is not configured, "foreign" otherwise.
owned_route_state() {
  ts serve status --json | python3 -c '
import json, sys
d = json.load(sys.stdin) or {}
port, target, host = sys.argv[1], sys.argv[2], sys.argv[3]
tcp = (d.get("TCP") or {}).get(port)
funnel = any(k.endswith(":" + port) and v for k, v in (d.get("AllowFunnel") or {}).items())
if tcp is None and not funnel:
    print("absent")
elif tcp and tcp.get("TCPForward") == target.removeprefix("tcp://") and not tcp.get("TerminateTLS") and not tcp.get("HTTPS") and funnel:
    print("on")
else:
    print("foreign")
' "$FUNNEL_PORT" "$FUNNEL_TARGET" "$FUNNEL_HOST"
}

die() { echo "error: $*" >&2; exit 1; }
