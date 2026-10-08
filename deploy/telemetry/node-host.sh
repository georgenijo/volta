# Sourced. Resolves the node's full MagicDNS name (<node>.<tailnet>.ts.net) from
# tailscale at run time so personal hostnames never live in Git. Callers let an
# explicit TELEMETRY_HOST / FUNNEL_HOST win and fail when neither resolves.
node_host() {
  tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null
}

# Reads KEY=value from a Compose-style dotenv file without executing it:
# leading whitespace, "export" and spaces around "=" are ignored, the last
# assignment wins, a quoted value ends at its closing quote, and an unquoted
# value ends at " #" (inline comment) with trailing whitespace removed.
# Prints nothing when the file or key is absent.
env_value() {
  [[ -r $1 ]] || return 0
  local line v out=""
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    [[ ${BASH_REMATCH[2]} == "$2" ]] || continue
    v="${BASH_REMATCH[3]}"
    # An unquoted value that is only whitespace and a comment is empty.
    [[ $v =~ ^[[:space:]]+# ]] && v=""
    v="${v#"${v%%[![:space:]]*}"}"
    case $v in
      \"*) v="${v#\"}"; v="${v%%\"*}" ;;
      \'*) v="${v#\'}"; v="${v%%\'*}" ;;
      *) v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}" ;;
    esac
    out="$v"
  done <"$1"
  printf '%s\n' "$out"
}
