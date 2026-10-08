# Sourced. Resolves the node's full MagicDNS name (<node>.<tailnet>.ts.net) from
# tailscale at run time so personal hostnames never live in Git. Callers let an
# explicit TELEMETRY_HOST / FUNNEL_HOST win and fail when neither resolves.
node_host() {
  tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null
}

# Reads KEY=value from a Compose-style dotenv file without executing it:
# leading whitespace and "export " are ignored, the last assignment wins, a
# quoted value ends at its closing quote, and an unquoted value ends at
# " #" (inline comment) with trailing whitespace removed. Prints nothing
# when the file or key is absent.
env_value() {
  [[ -r $1 ]] || return 0
  local line v out=""
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    [[ $line == "$2="* ]] || continue
    v="${line#"$2="}"
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
