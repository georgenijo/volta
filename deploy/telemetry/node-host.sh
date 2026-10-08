# Sourced. Resolves the node's full MagicDNS name (<node>.<tailnet>.ts.net) from
# tailscale at run time so personal hostnames never live in Git. Callers let an
# explicit TELEMETRY_HOST / FUNNEL_HOST win and fail when neither resolves.
node_host() {
  tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null
}

# Reads KEY=value from a dotenv-style file (last assignment wins, one level of
# surrounding quotes removed) without sourcing it. Prints nothing when the
# file or key is absent.
env_value() {
  [[ -r $1 ]] || return 0
  sed -n -E "s/^[[:space:]]*$2=//p" "$1" | tail -n1 | sed -E "s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}
