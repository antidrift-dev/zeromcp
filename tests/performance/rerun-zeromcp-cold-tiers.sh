#!/usr/bin/env bash
# Re-run ZeroMCP at the 60s and 180s tiers only.
# Original overnight run captured these tiers while the Docker Desktop network
# bridge on macOS was cold, dragging throughput down by 70-120% on fast
# languages. Re-running now (or at any time after the host has been doing
# sustained Docker traffic) gives clean numbers.
#
# Overwrites <lang>-60s.{json,log} and <lang>-180s.{json,log} in place.
# Re-runs the aggregator at the end to refresh the combined CSV/JSON.
#
# Usage:  bash tests/performance/rerun-zeromcp-cold-tiers.sh

set -u

REPO="/Users/chriswelker/Projects/antidrift/zeromcp"
OUT="/Users/chriswelker/Projects/antidrift/zeromcp-benchmarks/results/mixed-workload-zeromcp-overnight"
LANGS=(node python go rust ruby csharp java kotlin php swift)
DURATIONS=(180 60)  # warm host already, do longer first to keep it warm
INTERVAL=10
PORT=3000
CONTAINER=bench-mixed
AGGREGATOR="/Users/chriswelker/Projects/antidrift/zeromcp/tests/performance/aggregate-overnight.mjs"

mkdir -p "$OUT"
START_TS=$(date +%s)
echo "" >> "$OUT/_manifest.txt"
echo "=== RERUN OF COLD TIERS — $(date -Iseconds) ===" >> "$OUT/_manifest.txt"

cd "$REPO"

start_container() {
  local lang=$1
  case "$lang" in
    node)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint node zeromcp-bench-http-node server-bare.mjs >/dev/null 2>&1
      ;;
    python)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint python zeromcp-bench-http-python server-starlette.py >/dev/null 2>&1
      ;;
    go)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint ./server-chi zeromcp-bench-http-go >/dev/null 2>&1
      ;;
    rust)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint ./server-actix zeromcp-bench-http-rust >/dev/null 2>&1
      ;;
    ruby)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint bundle zeromcp-bench-http-ruby exec ruby server-rack.rb >/dev/null 2>&1
      ;;
    csharp)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint dotnet zeromcp-bench-http-csharp /bench/aspnet/bench-aspnet.dll >/dev/null 2>&1
      ;;
    java)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint sh zeromcp-bench-http-java -c 'java -cp "/bench/jars/*" ServerJavalin' >/dev/null 2>&1
      ;;
    kotlin)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint /bench/ktor/bin/bench-ktor zeromcp-bench-http-kotlin >/dev/null 2>&1
      ;;
    php)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint php zeromcp-bench-http-php -S 0.0.0.0:3000 server-slim.php >/dev/null 2>&1
      ;;
    swift)
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 \
        --entrypoint /bench/server-vapor zeromcp-bench-http-vapor >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

run_one() {
  local lang=$1
  local duration=$2
  local label="${lang}-${duration}s"
  echo "[$(date -Iseconds)] $label rerunning..." | tee -a "$OUT/_manifest.txt"

  docker rm -f "$CONTAINER" >/dev/null 2>&1
  if ! start_container "$lang"; then
    echo "[$(date -Iseconds)] $label CONTAINER_START_FAILED" | tee -a "$OUT/_manifest.txt"
    return 1
  fi

  local ready=0
  for i in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "[$(date -Iseconds)] $label HEALTH_TIMEOUT" | tee -a "$OUT/_manifest.txt"
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    return 1
  fi

  CONTAINER_NAME="$CONTAINER" node tests/performance/mixed-workload.mjs \
      "http://127.0.0.1:${PORT}/mcp" "$duration" "$INTERVAL" \
      > "$OUT/${label}.json" 2> "$OUT/${label}.log"
  local rc=$?

  docker rm -f "$CONTAINER" >/dev/null 2>&1

  if [ "$rc" != "0" ]; then
    echo "[$(date -Iseconds)] $label BENCH_FAILED rc=$rc" | tee -a "$OUT/_manifest.txt"
    return 1
  fi

  local summary
  summary=$(grep -E 'avg [0-9]+ rps' "$OUT/${label}.log" | tail -1 | tr -s ' ')
  echo "[$(date -Iseconds)] $label DONE  $summary" | tee -a "$OUT/_manifest.txt"
}

for duration in "${DURATIONS[@]}"; do
  echo "" | tee -a "$OUT/_manifest.txt"
  echo "=== Rerun tier: ${duration}s ===" | tee -a "$OUT/_manifest.txt"
  for lang in "${LANGS[@]}"; do
    run_one "$lang" "$duration" || true
  done
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo "" >> "$OUT/_manifest.txt"
echo "rerun finished: $(date -Iseconds)" >> "$OUT/_manifest.txt"
echo "rerun elapsed: ${ELAPSED}s ($((ELAPSED/60)) min)" >> "$OUT/_manifest.txt"

docker rm -f "$CONTAINER" >/dev/null 2>&1

echo ""
echo "Re-running aggregator..."
node "$AGGREGATOR"
echo ""
echo "DONE."
