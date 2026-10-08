#!/usr/bin/env bash
# Creates the two receiver topics with bounded retention. Idempotent: an
# existing topic gets its retention re-applied instead.
set -euo pipefail
ns="${TELEMETRY_NAMESPACE:-tesla_telemetry}"
retention_ms=604800000       # 7 days
retention_bytes=1073741824   # 1 GiB per partition
# Cluster defaults: no implicit topics, fsync before ack, bounded default.
rpk cluster config set auto_create_topics_enabled false >/dev/null
rpk cluster config set write_caching_default false >/dev/null
rpk cluster config set log_retention_ms "$retention_ms" >/dev/null
for topic in "${ns}_V" "${ns}_connectivity"; do
  if rpk topic describe "$topic" >/dev/null 2>&1; then
    rpk topic alter-config "$topic" \
      --set retention.ms="$retention_ms" \
      --set retention.bytes="$retention_bytes" \
      --set cleanup.policy=delete \
      --set write.caching=false >/dev/null
  else
    rpk topic create "$topic" -p 1 -r 1 \
      -c retention.ms="$retention_ms" \
      -c retention.bytes="$retention_bytes" \
      -c cleanup.policy=delete \
      -c write.caching=false >/dev/null
  fi
done
echo "telemetry topics ready"
