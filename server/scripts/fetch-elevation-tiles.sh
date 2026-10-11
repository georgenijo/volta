#!/usr/bin/env bash
# Fetch public Skadi tiles by name. Select names on the private database host;
# the only upstream requests are public 1-degree tile objects, never GPS fixes.
#   fetch-elevation-tiles.sh <out-dir> --tiles-file <private-manifest>
# Legacy bounding-box arguments are also accepted (converted locally to names).
# Existing valid tiles are kept. No coordinates or tile names are logged.
set -euo pipefail
if [[ $# -ne 3 && $# -ne 5 ]]; then
  echo "usage: $0 <out-dir> --tiles-file <manifest> | <out-dir> <min-lat> <min-lon> <max-lat> <max-lon>" >&2
  exit 2
fi
out=$1
names=$(python3 -I - "${@:2}" <<'PY'
import math, re, sys
args = sys.argv[1:]
try:
    if len(args) == 2 and args[0] == '--tiles-file':
        with open(args[1]) as f:
            names = sorted(set(line.strip() for line in f if line.strip()))
        for name in names:
            if not re.fullmatch(r'(N(?:[0-8][0-9])|S(?:0[1-9]|[1-8][0-9]|90))(E(?:0[0-9]{2}|1[0-7][0-9])|W(?:00[1-9]|0[1-9][0-9]|1[0-7][0-9]|180))', name):
                sys.exit('invalid tile name in manifest')
    elif len(args) == 4:
        a, b, c, d = map(float, args)
        if not all(math.isfinite(v) for v in (a,b,c,d)) or not (-90 <= a <= c <= 90 and -180 <= b <= d <= 180):
            sys.exit('invalid bounding box')
        lat0, lat1 = min(89,math.floor(a)), min(89,math.floor(c))
        lon0, lon1 = min(179,math.floor(b)), min(179,math.floor(d))
        if (lat1-lat0+1)*(lon1-lon0+1) > 400:
            sys.exit('refusing to fetch more than 400 tiles in one run')
        names = [f'{"S" if lat<0 else "N"}{abs(lat):02d}{"W" if lon<0 else "E"}{abs(lon):03d}'
                 for lat in range(lat0,lat1+1) for lon in range(lon0,lon1+1)]
    else:
        sys.exit('expected --tiles-file <manifest> or four bounds')
except (OSError, ValueError):
    sys.exit('could not read tile manifest or bounds')
if not names or len(names) > 400:
    sys.exit('need between 1 and 400 unique tile names')
print('\n'.join(names))
PY
)
mkdir -p "$out"
base=https://s3.amazonaws.com/elevation-tiles-prod/skadi
fetched=0 skipped=0 missing=0
while IFS= read -r name; do
  row=${name:0:3}
  target="$out/$row/$name.hgt"
  if [[ -f $target ]]; then
    size=$(wc -c <"$target")
    if [[ $size -eq 2884802 || $size -eq 25934402 ]]; then skipped=$((skipped+1)); continue; fi
  fi
  mkdir -p "$out/$row"
  tmp=$(mktemp "$out/$row/.tile.XXXXXX")
  trap 'rm -f "$tmp" "$tmp.hgt"' EXIT
  code=$(curl -sS --retry 3 -o "$tmp" -w '%{http_code}' "$base/$row/$name.hgt.gz" || true)
  if [[ $code == 200 ]] && gzip -dc "$tmp" >"$tmp.hgt" 2>/dev/null && size=$(wc -c <"$tmp.hgt") && [[ $size -eq 2884802 || $size -eq 25934402 ]]; then
    chmod 644 "$tmp.hgt"
    mv "$tmp.hgt" "$target"; fetched=$((fetched+1))
  elif [[ $code == 403 || $code == 404 ]]; then
    missing=$((missing+1))
  else
    echo "tile download failed (HTTP $code)" >&2; exit 1
  fi
  rm -f "$tmp" "$tmp.hgt"
done <<<"$names"
trap - EXIT
echo "tiles: $fetched fetched, $skipped already present, $missing not available"
