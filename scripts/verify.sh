#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <path-to-wasm>"
    exit 1
fi

WASM_FILE=$1

echo "=== Verifying $WASM_FILE ==="

# 1. Валидация артефакта
echo -n "[1/5] Validating artifact... "
wasm-tools validate --features all "$WASM_FILE"
echo "✅ Valid"

# 2. Извлечение интерфейса (JSON)
echo -n "[2/5] Extracting interface... "
wasm-tools component wit --json "$WASM_FILE" > /tmp/interface.json
echo "✅ Extracted to /tmp/interface.json"

# 3. Проверка зависимостей
echo -n "[3/5] Checking dependencies... "
OUT_DIR=$(mktemp -d)
wasm-tools component wit "$WASM_FILE" --out-dir "$OUT_DIR" > /dev/null 2>&1 || true
if [ -d "$OUT_DIR/deps" ] && [ "$(ls -A "$OUT_DIR/deps")" ]; then
    echo "⚠️ Has WASI dependencies"
else
    echo "✅ No external dependencies"
fi
rm -rf "$OUT_DIR"

# 4. Генерация Host-контракта (--importize)
echo -n "[4/5] Generating Host contract... "
if wasm-tools component wit "$WASM_FILE" --importize > /dev/null 2>&1; then
    echo "✅ Host WIT generated successfully"
else
    echo "❌ Failed to generate Host WIT"
    exit 1
fi

# 5. Precompilation (wasmtime compile)
echo -n "[5/5] Precompiling to native code... "
wasmtime compile --target x86_64-unknown-linux-gnu "$WASM_FILE" -o /tmp/component.cwasm
echo "✅ Compiled to /tmp/component.cwasm"

echo "=== All structural checks passed ==="