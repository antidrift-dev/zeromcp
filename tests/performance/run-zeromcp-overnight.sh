#!/usr/bin/env bash
# Overnight sustained mixed-workload runner for ZeroMCP across 10 languages.
# Best framework per language. Same workload as the official SDK overnight,
# so the two output directories are directly comparable run-for-run.
#
# Order: by-duration (outer loop), so the 1m matrix completes first.
#
# Usage:  bash tests/performance/run-zeromcp-overnight.sh
# Output: zeromcp-benchmarks/results/mixed-workload-zeromcp-overnight/
#         <lang>-<duration>s.{json,log} per run
#         _manifest.txt with completion summary

set -u

REPO="/Users/chriswelker/Projects/antidrift/zeromcp"
OUT="/Users/chriswelker/Projects/antidrift/zeromcp-benchmarks/results/mixed-workload-zeromcp-overnight"
LANGS=(node python go rust ruby csharp java kotlin php swift)
DURATIONS=(600 300 180 60)  # reversed: longest first, so cold-Docker effect doesn't taint short tiers
INTERVAL=10
PORT=3000
CONTAINER=bench-mixed

mkdir -p "$OUT"
START_TS=$(date +%s)
echo "started: $(date -Iseconds)" > "$OUT/_manifest.txt"
echo "host: $(hostname)" >> "$OUT/_manifest.txt"
echo "" >> "$OUT/_manifest.txt"

cd "$REPO"

# Start the best framework binary per language. Returns the docker run command
# arguments after the image name.
start_container() {
  local lang=$1
  local image entry args
  case "$lang" in
    node)
      image="zeromcp-bench-http-node"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint node "$image" server-bare.mjs >/dev/null 2>&1
      ;;
    python)
      image="zeromcp-bench-http-python"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint python "$image" server-starlette.py >/dev/null 2>&1
      ;;
    go)
      image="zeromcp-bench-http-go"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint ./server-chi "$image" >/dev/null 2>&1
      ;;
    rust)
      image="zeromcp-bench-http-rust"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint ./server-actix "$image" >/dev/null 2>&1
      ;;
    ruby)
      image="zeromcp-bench-http-ruby"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint bundle "$image" exec ruby server-rack.rb >/dev/null 2>&1
      ;;
    csharp)
      image="zeromcp-bench-http-csharp"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint dotnet "$image" /bench/aspnet/bench-aspnet.dll >/dev/null 2>&1
      ;;
    java)
      image="zeromcp-bench-http-java"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint sh "$image" -c 'java -cp "/bench/jars/*" ServerJavalin' >/dev/null 2>&1
      ;;
    kotlin)
      image="zeromcp-bench-http-kotlin"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint /bench/ktor/bin/bench-ktor "$image" >/dev/null 2>&1
      ;;
    php)
      image="zeromcp-bench-http-php"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 -w /bench \
        --entrypoint php "$image" -S 0.0.0.0:3000 server-slim.php >/dev/null 2>&1
      ;;
    swift)
      image="zeromcp-bench-http-vapor"
      docker run -d --name "$CONTAINER" -p "${PORT}:3000" -e PORT=3000 \
        --entrypoint /bench/server-vapor "$image" >/dev/null 2>&1
      ;;
    *)
      echo "Unknown language: $lang" >&2
      return 1
      ;;
  esac
}

run_one() {
  local lang=$1
  local duration=$2
  local label="${lang}-${duration}s"
  local started
  started=$(date -Iseconds)

  echo "[$started] $label starting..." | tee -a "$OUT/_manifest.txt"

  docker rm -f "$CONTAINER" >/dev/null 2>&1

  if ! start_container "$lang"; then
    echo "[$(date -Iseconds)] $label CONTAINER_START_FAILED" | tee -a "$OUT/_manifest.txt"
    return 1
  fi

  # Wait up to 90s for health
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
    docker logs "$CONTAINER" > "$OUT/${label}.docker.log" 2>&1
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
  return 0
}

for duration in "${DURATIONS[@]}"; do
  echo "" | tee -a "$OUT/_manifest.txt"
  echo "=== Duration tier: ${duration}s ===" | tee -a "$OUT/_manifest.txt"
  for lang in "${LANGS[@]}"; do
    run_one "$lang" "$duration" || true
  done
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo "" >> "$OUT/_manifest.txt"
echo "finished: $(date -Iseconds)" >> "$OUT/_manifest.txt"
echo "elapsed: ${ELAPSED}s ($((ELAPSED/60)) min)" >> "$OUT/_manifest.txt"

docker rm -f "$CONTAINER" >/dev/null 2>&1
echo ""
echo "DONE. Manifest at $OUT/_manifest.txt"
