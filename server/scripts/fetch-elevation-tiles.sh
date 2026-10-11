#!/usr/bin/env bash
# Download public SRTM-derived Skadi .hgt tiles (1x1 degree, from the AWS
# Open Data "Terrain Tiles" bucket elevation-tiles-prod) for one bounding box
# into ELEVATION_DEM_DIR's layout: <dir>/N37/N37W123.hgt.
#
#   fetch-elevation-tiles.sh <out-dir> <min-lat> <min-lon> <max-lat> <max-lon>
#
# Every argument is required; there is no default region. Run it where the
# API runs (or copy the directory there) and set ELEVATION_DEM_DIR=<out-dir>.
# The API itself never downloads anything. Existing tiles are kept; tiles the
# bucket does not have (open ocean) are skipped. Skadi tiles are 1 arc-second:
# ~26 MB each on disk (about 7 MB to download).
set -euo pipefail
if [[ $# -ne 5 ]]; then
  echo "usage: $0 <out-dir> <min-lat> <min-lon> <max-lat> <max-lon>" >&2
  exit 2
fi
out=$1
read -r lat0 lon0 lat1 lon1 count < <(python3 -I - "$2" "$3" "$4" "$5" <<'PY'
import math, sys
try:
    a, b, c, d = (float(v) for v in sys.argv[1:5])
except ValueError:
    sys.exit("bounds must be numbers")
if not all(math.isfinite(v) for v in (a, b, c, d)) or not (-90 <= a <= c <= 90 and -180 <= b <= d <= 180):
    sys.exit("need -90 <= min-lat <= max-lat <= 90 and -180 <= min-lon <= max-lon <= 180")
lat0, lon0 = math.floor(a), math.floor(b)
lat0, lon0 = min(89, lat0), min(179, lon0)
lat1, lon1 = min(89, math.floor(c)), min(179, math.floor(d))
print(lat0, lon0, lat1, lon1, (lat1 - lat0 + 1) * (lon1 - lon0 + 1))
PY
)
if (( count > 400 )); then
  echo "refusing to fetch $count tiles in one run; split the bounding box" >&2
  exit 2
fi
mkdir -p "$out"
base=https://s3.amazonaws.com/elevation-tiles-prod/skadi
fetched=0 skipped=0 missing=0
for ((lat=lat0; lat<=lat1; lat++)); do
  for ((lon=lon0; lon<=lon1; lon++)); do
    ns=$([[ $lat -lt 0 ]] && echo S || echo N); ew=$([[ $lon -lt 0 ]] && echo W || echo E)
    row=$(printf '%s%02d' "$ns" "${lat#-}"); name=$(printf '%s%s%03d' "$row" "$ew" "${lon#-}")
    target="$out/$row/$name.hgt"
    if [[ -s $target ]]; then skipped=$((skipped+1)); continue; fi
    mkdir -p "$out/$row"
    tmp=$(mktemp "$out/$row/.$name.XXXXXX")
    code=$(curl -sS --retry 3 -o "$tmp" -w '%{http_code}' "$base/$row/$name.hgt.gz" || true)
    if [[ $code == 200 ]] && gzip -dc "$tmp" >"$tmp.hgt" && size=$(wc -c <"$tmp.hgt") && [[ $size -eq 2884802 || $size -eq 25934402 ]]; then
      mv "$tmp.hgt" "$target"; fetched=$((fetched+1))
    elif [[ $code == 403 || $code == 404 ]]; then
      missing=$((missing+1))
    else
      rm -f "$tmp" "$tmp.hgt"; echo "failed: $name (HTTP $code)" >&2; exit 1
    fi
    rm -f "$tmp" "$tmp.hgt"
  done
done
echo "tiles: $fetched fetched, $skipped already present, $missing not available"
