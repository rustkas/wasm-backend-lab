#!/usr/bin/env bash
# scripts/measure.sh
#
# Сравнивает native-baseline и wasm-хост (host_v2) на одной и той же логике
# (normalize_text). Оба сервера поднимаются, прогреваются, замеряются
# (interleaved) и сравниваются на эквивалентность вывода.
#
# Архитектура артефактов (см. Главы 1–3 книги):
#
#   crate                           | тип               | путь к артефакту
#   --------------------------------|-------------------|--------------------------------------------------------------
#   components/text-engine          | pure Rust baseline | target/wasm32-wasip1/release/text_engine.wasm               ← MODULE, НЕ component
#   components/text-engine-core     | Core WASM demo     | target/wasm32-wasip1/release/text_engine_core.wasm          ← MODULE, НЕ component
#   components/text-engine-component| Component Model    | components/text-engine-component/target/wasm32-wasip1/release/text_engine_component.wasm
#   components/document-engine      | Component (record) | components/document-engine/target/wasm32-wasip1/release/document_engine.wasm
#
# host_v2 требует Component Model (parses via wasmtime::component::Component).
# Обычные wasm-модули (любой .wasm из первых двух строк таблицы) будут
# отвергнуты с `attempted to parse a wasm module with a component parser`.
# Это by design книги: text-engine и text-engine-core — не компоненты.
#
# Note on measurement. Каждый `curl` — отдельный процесс; `time_total` не
# включает старт curl, но включает connect + TTFB + download. Для точных
# замеров нужен hyperfine или многопоточный клиент; при n=20–50 медиана и
# p95 уже показывают устойчивую разницу.
#
# Переопределяемые параметры:
#   NATIVE_PORT     порт native-baseline (по умолчанию 3001)
#   WASM_PORT       порт host_v2         (по умолчанию 3002)
#   WARMUP          прогревочных запросов на сервер (по умолчанию 5)
#   REQUESTS        замеров на сервер (по умолчанию 20)
#   INPUT_JSON      JSON-payload
#   COMPONENT_WASM  путь к *.wasm-КОМПОНЕНТУ (не модулю!). Если задан —
#                   скрипт НЕ пересобирает text-engine-component и использует
#                   указанный артефакт. Это для тестирования АЛЬТЕРНАТИВНЫХ
#                   реализаций с тем же WIT-интерфейсом
#                   (docs:text-engine/processor). text_engine.wasm сюда
#                   передавать НЕЛЬЗЯ — это модуль, не компонент.
#
# Примеры:
#   ./scripts/measure.sh
#   REQUESTS=50 WARMUP=10 ./scripts/measure.sh
#   COMPONENT_WASM=/path/to/alt_component.wasm ./scripts/measure.sh

set -euo pipefail

NATIVE_PORT="${NATIVE_PORT:-3001}"
WASM_PORT="${WASM_PORT:-3002}"
WARMUP="${WARMUP:-5}"
REQUESTS="${REQUESTS:-20}"
INPUT_JSON="${INPUT_JSON:-{\"input\":\"  Hello   WASM   World  \"}}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG_NATIVE="/tmp/wasm-lab-native.log"
LOG_WASM="/tmp/wasm-lab-wasm.log"

echo "Repo root:       $ROOT"
echo "Native binary:   $ROOT/target/release/native-baseline   (port $NATIVE_PORT)"
echo "WASM binary:     $ROOT/target/release/host_v2           (port $WASM_PORT)"
echo "Logs:            $LOG_NATIVE"
echo "                 $LOG_WASM"
echo "Warmup:          $WARMUP requests each"
echo "Measured:        $REQUESTS requests each (interleaved)"
echo

# --- 1. Kill stale servers ------------------------------------------------
echo "=== 1. Killing stale servers ==="
pkill -f 'target/release/host'            2>/dev/null || true
pkill -f 'target/release/native-baseline' 2>/dev/null || true
sleep 1

# --- 2. Build -------------------------------------------------------------
echo "=== 2. Building ==="
cargo build --package native-baseline --release --quiet

if [ -n "${COMPONENT_WASM:-}" ]; then
  # Пользователь дал конкретный артефакт. Пересобирать text-engine-component
  # не нужно (он мог собрать свою альтернативную реализацию).
  echo "ℹ️  COMPONENT_WASM override: $COMPONENT_WASM (skipping default component build)"
else
  # По умолчанию: единственный совместимый с native-baseline компонент.
  COMPONENT_WASM="$ROOT/components/text-engine-component/target/wasm32-wasip1/release/text_engine_component.wasm"
  (cd components/text-engine-component && cargo component build --release --quiet)
fi

cargo build --package host --release --quiet

# --- 2a. Verify artifact is a component -----------------------------------
if [ ! -f "$COMPONENT_WASM" ]; then
  echo "❌ component artifact not found: $COMPONENT_WASM"
  case "$COMPONENT_WASM" in
    */components/text-engine/target/*|*/components/text-engine-core/target/*)
      echo "   NOTE: text-engine and text-engine-core are workspace members —"
      echo "         их артефакты лежат в $ROOT/target/wasm32-wasip1/release/"
      echo "         Но главное: это МОДУЛИ, а не компоненты. host_v2 их отвергнет." ;;
    */target/wasm32-wasip1/release/text_engine.wasm|\
    */target/wasm32-wasip1/release/text_engine_core.wasm)
      echo "   NOTE: это Core WASM-модули, а не Component Model артефакты."
      echo "         host_v2 требует component (parses via wasmtime::component::Component)."
      echo "         Используйте components/text-engine-component/target/wasm32-wasip1/release/text_engine_component.wasm" ;;
    */components/text-engine-component/*)
      echo "   (build it with: cd components/text-engine-component && cargo component build --release)" ;;
    *)
      echo "   (COMPONENT_WASM points outside known dirs — build it manually)" ;;
  esac
  exit 1
fi

if command -v wasm-tools >/dev/null 2>&1; then
  HEAD="$(wasm-tools print "$COMPONENT_WASM" 2>/dev/null | head -n 1 || true)"
  case "$HEAD" in
    "(component "*)
      echo "✅ component artifact: $COMPONENT_WASM" ;;
    *)
      echo "❌ not a component-model artifact: $COMPONENT_WASM"
      echo "   first line: $HEAD"
      case "$COMPONENT_WASM" in
        */text_engine.wasm)
          echo "   hint: text-engine — это Baseline из Главы 1, компилируется в module,"
          echo "         а не в component (по дизайну книги)."
          echo "         host_v2 работает только с Component Model." ;;
        */text_engine_core.wasm)
          echo "   hint: text-engine-core — Core WASM демо из Главы 2, это module."
          echo "         Component Model с той же логикой — text-engine-component." ;;
        *)
          echo "   hint: a plain \`cargo build --target wasm32-wasip1\` output is a *module*,"
          echo "         not a *component*; host_v2 requires the latter." ;;
      esac
      exit 1 ;;
  esac
else
  echo "ℹ️  wasm-tools not installed — skipping artifact sanity check"
  echo "   (install: cargo install wasm-tools --locked)"
fi
echo "Component:       $COMPONENT_WASM"
echo

# --- 3. Start servers -----------------------------------------------------
echo "=== 3. Starting servers ==="

"$ROOT/target/release/native-baseline" >"$LOG_NATIVE" 2>&1 &
NATIVE_PID=$!

TEXT_ENGINE_WASM="$COMPONENT_WASM" "$ROOT/target/release/host_v2" >"$LOG_WASM" 2>&1 &
WASM_PID=$!

cleanup() {
  kill "$NATIVE_PID" "$WASM_PID" 2>/dev/null || true
  wait "$NATIVE_PID" "$WASM_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 1
if ! kill -0 "$NATIVE_PID" 2>/dev/null; then
  echo "❌ native server died"
  echo "--- $LOG_NATIVE ---"; cat "$LOG_NATIVE" || true
  exit 1
fi
if ! kill -0 "$WASM_PID" 2>/dev/null; then
  echo "❌ wasm server died"
  echo "--- $LOG_WASM ---"; cat "$LOG_WASM" || true
  exit 1
fi

# --- helpers ---------------------------------------------------------------
measure_one() {
  curl -s -f -o /dev/null --max-time 10 -w "%{time_total}" \
    -X POST "$1" \
    -H "Content-Type: application/json" \
    -d "$INPUT_JSON"
}

report_stats() {
  local label="$1" times="$2"
  echo "$times" | tr ' ' '\n' | grep -v '^$' | sort -n | awk -v label="$label" '
    { v[NR]=$1; s+=$1 }
    END {
      n=NR
      if (n==0) { print label ": no samples"; exit 1 }
      med = (n%2==1) ? v[(n+1)/2] : (v[n/2]+v[n/2+1])/2
      p95i = int(n*0.95); if (p95i < 1) p95i = 1
      printf "%s: n=%d min=%.4fs med=%.4fs avg=%.4fs p95=%.4fs max=%.4fs\n",
        label, n, v[1], med, s/n, v[p95i], v[n]
    }'
}

# --- 4. Warmup ------------------------------------------------------------
echo "=== 4. Warmup ($WARMUP requests each) ==="
for i in $(seq 1 "$WARMUP"); do
  measure_one "http://127.0.0.1:$NATIVE_PORT/process" >/dev/null || {
    echo "❌ native warmup failed (request #$i)"
    echo "--- $LOG_NATIVE ---"; cat "$LOG_NATIVE" || true
    exit 1
  }
  measure_one "http://127.0.0.1:$WASM_PORT/process" >/dev/null || {
    echo "❌ wasm warmup failed (request #$i)"
    echo "--- $LOG_WASM ---"; cat "$LOG_WASM" || true
    exit 1
  }
done
echo

# --- 5. Measure (interleaved) --------------------------------------------
echo "=== 5. Measure ($REQUESTS requests each, interleaved) ==="
NATIVE_TIMES=""
WASM_TIMES=""
for i in $(seq 1 "$REQUESTS"); do
  T="$(measure_one "http://127.0.0.1:$NATIVE_PORT/process")" || {
    echo "❌ native request #$i failed"
    echo "--- $LOG_NATIVE ---"; cat "$LOG_NATIVE" || true
    exit 1
  }
  NATIVE_TIMES="$NATIVE_TIMES $T"

  T="$(measure_one "http://127.0.0.1:$WASM_PORT/process")" || {
    echo "❌ wasm request #$i failed"
    echo "--- $LOG_WASM ---"; cat "$LOG_WASM" || true
    exit 1
  }
  WASM_TIMES="$WASM_TIMES $T"
done
echo

# --- 6. Statistics --------------------------------------------------------
echo "=== 6. Statistics ==="
report_stats "Native" "$NATIVE_TIMES"
report_stats "WASM  " "$WASM_TIMES"
echo

# --- 7. Verify equivalence ------------------------------------------------
echo "=== 7. Verify equivalence ==="
echo "Artifact: $COMPONENT_WASM"
NATIVE_RESP="$(curl -s -f --max-time 10 -X POST "http://127.0.0.1:$NATIVE_PORT/process" \
  -H "Content-Type: application/json" -d "$INPUT_JSON")"
WASM_RESP="$(curl -s -f --max-time 10 -X POST "http://127.0.0.1:$WASM_PORT/process" \
  -H "Content-Type: application/json" -d "$INPUT_JSON")"

echo "Native: $NATIVE_RESP"
echo "WASM:   $WASM_RESP"

if [ "$NATIVE_RESP" = "$WASM_RESP" ]; then
  echo "✅ Identical output."
else
  echo "❌ Outputs differ."
  exit 1
fi