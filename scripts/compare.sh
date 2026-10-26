#!/bin/bash
set -e

# Переходим в корень проекта
cd "$(dirname "$0")/.."

echo "=== 1. Building Native Baseline ==="
cargo build --package native-baseline --release

echo "=== 2. Building WASM Component ==="
(cd components/text-engine && cargo component build --release)

echo "=== 3. Building WASM Host ==="
cargo build --package host --release

echo "=== 4. Starting Servers ==="
# Запускаем Native
./target/release/native-baseline > /tmp/native.log 2>&1 &
NATIVE_PID=$!

# Запускаем WASM Host
./target/release/host > /tmp/wasm.log 2>&1 &
WASM_PID=$!

# Даем серверам время запуститься
sleep 2

# Функция очистки при выходе
cleanup() {
    echo "Shutting down servers..."
    kill $NATIVE_PID $WASM_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "=== 5. Running Comparison ==="
INPUT_JSON='{"input": "hello wasm infrastructure"}'

echo "--- Native Baseline Response ---"
NATIVE_RESP=$(curl -s -X POST http://127.0.0.1:3001/process -H "Content-Type: application/json" -d "$INPUT_JSON")
echo "$NATIVE_RESP"

echo "--- WASM Host Response ---"
WASM_RESP=$(curl -s -X POST http://127.0.0.1:3000/process -H "Content-Type: application/json" -d "$INPUT_JSON")
echo "$WASM_RESP"

echo "=== 6. Verification ==="
if [ "$NATIVE_RESP" == "$WASM_RESP" ]; then
    echo "✅ SUCCESS: Both implementations returned the same result!"
else
    echo "❌ FAILURE: Results differ!"
    echo "--- WASM Host Log ---"
    cat /tmp/wasm.log
    exit 1
fi