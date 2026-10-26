#!/usr/bin/env bash
# scripts/init-demo-web-ui.sh
#
# Идемпотентно создаёт demo-web-ui/ — дополнительный проект к Главе 5.
#
# Что делает:
#   1. Регистрирует demo-web-ui в workspace (через `cargo new --vcs none`).
#   2. Пишет demo-web-ui/Cargo.toml (host + axum + tokio + anyhow).
#   3. Пишет demo-web-ui/src/main.rs (переиспользует host::Runtime / host::http::router).
#   4. Пишет demo-web-ui/static/index.html (полный интерактивный UI).
#   5. Проверяет, что пакет в workspace, собран и готов к запуску.
#
# ВНИМАНИЕ: шаг 4 ВСЕГДА перезаписывает static/index.html.
# Если вы кастомизировали UI — закоммитьте его перед повторным запуском.
#
# Требования:
#   - Запускать из корня workspace (или из любого места: скрипт сам найдёт).
#   - Компонент components/text-engine-component должен быть собран
#     (`cargo component build --release`) — иначе demo-web-ui запустится,
#     но напечатает ошибку про отсутствующий .wasm.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- 0. Проверка, что мы там, где надо -------------------------------------
if [ ! -f "Cargo.toml" ] || ! grep -q '^\[workspace\]' Cargo.toml 2>/dev/null; then
  echo "❌ Не найден корневой Cargo.toml с [workspace]. Запустите скрипт из корня workspace."
  exit 1
fi
if [ ! -f "host/Cargo.toml" ]; then
  echo "❌ Не найден host/Cargo.toml. demo-web-ui зависит от пакета host."
  exit 1
fi

# --- 1. Крейт (автоматически регистрируется в workspace) -------------------
if [ ! -d "demo-web-ui" ]; then
  cargo new demo-web-ui --bin --vcs none
  echo "✅ created crate demo-web-ui (auto-registered in workspace members)"
else
  echo "ℹ️  demo-web-ui/ already exists, skipping cargo new"
fi

# --- 2. Cargo.toml ---------------------------------------------------------
cat > demo-web-ui/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui"
version.workspace = true
edition.workspace = true

[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
anyhow = "1.0"
EOF
echo "✅ demo-web-ui/Cargo.toml"

# --- 3. src/main.rs --------------------------------------------------------
mkdir -p demo-web-ui/src
cat > demo-web-ui/src/main.rs <<'EOF'
use axum::{response::Html, routing::get, Router};
use host::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let wasm_path = host::default_wasm_path();
    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!(
            "Run `cd components/text-engine-component && cargo component build --release` first."
        );
        std::process::exit(1);
    }

    println!("Loading component: {}", wasm_path.display());
    let runtime = Runtime::new(&wasm_path)?;

    // host::http::router уже содержит POST /process; добавляем только GET /
    let app: Router = host::http::router(runtime).route("/", get(index));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3003").await?;
    println!("🚀 Demo UI: http://127.0.0.1:3003");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF
echo "✅ demo-web-ui/src/main.rs"

# --- 4. static/index.html (перезаписываем всегда) --------------------------
mkdir -p demo-web-ui/static
if [ -f demo-web-ui/static/index.html ]; then
  echo "ℹ️  overwriting existing demo-web-ui/static/index.html"
fi
cat > demo-web-ui/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>WASM Component Demo</title>
  <style>
    :root {
      --bg: #0f172a;
      --panel: #1e293b;
      --border: #334155;
      --text: #e2e8f0;
      --muted: #94a3b8;
      --accent: #38bdf8;
      --accent-hover: #0ea5e9;
      --success: #22c55e;
      --error: #ef4444;
      --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg); color: var(--text);
      min-height: 100vh; display: flex; align-items: center; justify-content: center;
      padding: 2rem;
    }
    .container {
      max-width: 820px; width: 100%;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 2rem;
      box-shadow: 0 20px 60px rgba(0,0,0,0.4);
    }
    header { margin-bottom: 2rem; text-align: center; }
    h1 {
      font-size: 1.75rem; font-weight: 600; margin-bottom: 0.5rem;
      background: linear-gradient(135deg, var(--accent), #a78bfa);
      -webkit-background-clip: text;
              background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .subtitle { color: var(--muted); font-size: 0.9rem; }
    .subtitle code {
      font-family: var(--mono);
      background: rgba(255,255,255,0.05);
      padding: 0.15rem 0.4rem; border-radius: 4px; color: var(--accent);
    }
    label {
      display: block; font-size: 0.8rem; font-weight: 500;
      color: var(--muted); margin-bottom: 0.5rem;
      text-transform: uppercase; letter-spacing: 0.05em;
    }
    textarea {
      width: 100%; min-height: 120px; padding: 1rem;
      font-family: var(--mono); font-size: 0.9rem;
      background: var(--bg); color: var(--text);
      border: 1px solid var(--border); border-radius: 8px;
      resize: vertical; outline: none; transition: border-color 0.15s;
    }
    textarea:focus { border-color: var(--accent); }
    .presets {
      display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center;
      margin-top: 0.75rem;
    }
    .presets > span { font-size: 0.75rem; color: var(--muted); margin-right: 0.25rem; }
    .actions {
      display: flex; gap: 0.75rem; margin-top: 1.25rem; flex-wrap: wrap;
    }
    button {
      padding: 0.65rem 1.25rem; font-size: 0.9rem; font-weight: 500;
      border: none; border-radius: 8px; cursor: pointer; transition: all 0.15s;
    }
    button.primary { background: var(--accent); color: #0c1222; }
    button.primary:hover { background: var(--accent-hover); }
    button.primary:disabled { opacity: 0.5; cursor: wait; }
    button.secondary {
      background: transparent; color: var(--muted);
      border: 1px solid var(--border);
      font-family: var(--mono); font-size: 0.78rem;
    }
    button.secondary:hover { color: var(--text); border-color: var(--accent); }
    .result {
      margin-top: 1.5rem; padding: 1rem;
      background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
      min-height: 70px;
    }
    .result-label {
      font-size: 0.72rem; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5rem;
      display: flex; justify-content: space-between; align-items: baseline;
    }
    .result-body {
      font-family: var(--mono); font-size: 0.9rem;
      white-space: pre-wrap; word-break: break-word;
      color: var(--muted);
    }
    .result-body.success { color: var(--success); }
    .result-body.error   { color: var(--error); }
    .timing { font-family: var(--mono); font-size: 0.75rem; color: var(--accent); }
    .badge {
      display: inline-block; font-size: 0.68rem; font-weight: 600;
      padding: 0.15rem 0.45rem; border-radius: 4px; margin-left: 0.5rem;
      background: rgba(56,189,248,0.15); color: var(--accent);
      text-transform: uppercase; letter-spacing: 0.05em; vertical-align: middle;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>WASM Component Demo</h1>
      <p class="subtitle">
        Calls <code>text-engine-component.wasm</code> via Wasmtime + Component Model
      </p>
    </header>

    <label for="input">
      Input text <span class="badge">POST /process</span>
    </label>
    <textarea id="input" spellcheck="false">  Hello   WASM   World  </textarea>

    <div class="presets">
      <span>Presets:</span>
      <button class="secondary" data-input="  Hello   WASM   World  ">extra spaces</button>
      <button class="secondary" data-input="RUST &#10; is &#13;&#10; AWESOME">newlines</button>
      <button class="secondary" data-input="!!! ???">specials</button>
      <button class="secondary" data-input="">empty</button>
    </div>

    <div class="actions">
      <button class="primary" id="run-btn">Process via WASM →</button>
    </div>

    <div class="result">
      <div class="result-label">
        <span>Result</span>
        <span class="timing" id="timing"></span>
      </div>
      <div class="result-body" id="output">Ready. Click "Process via WASM".</div>
    </div>
  </div>

  <script>
    const inputEl  = document.getElementById('input');
    const outputEl = document.getElementById('output');
    const timingEl = document.getElementById('timing');
    const runBtn   = document.getElementById('run-btn');

    document.querySelectorAll('.presets button').forEach(btn => {
      btn.addEventListener('click', () => {
        inputEl.value = btn.dataset.input;
        inputEl.focus();
      });
    });

    async function run() {
      runBtn.disabled = true;
      outputEl.className = 'result-body';
      outputEl.textContent = 'Calling WASM component...';
      timingEl.textContent = '';

      const t0 = performance.now();
      try {
        const resp = await fetch('/process', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ input: inputEl.value }),
        });
        const data = await resp.json();
        const ms = performance.now() - t0;
        timingEl.textContent = 'round-trip: ' + ms.toFixed(2) + ' ms';

        if (data.error) {
          outputEl.className = 'result-body error';
          outputEl.textContent = 'Error: ' + data.error;
        } else {
          outputEl.className = 'result-body success';
          outputEl.textContent = data.output === '' ? '(empty string)' : data.output;
        }
      } catch (e) {
        outputEl.className = 'result-body error';
        outputEl.textContent = 'Network error: ' + e;
      } finally {
        runBtn.disabled = false;
      }
    }

    runBtn.addEventListener('click', run);
    inputEl.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
        e.preventDefault();
        run();
      }
    });
  </script>
</body>
</html>
HTML_EOF
echo "✅ demo-web-ui/static/index.html"

# --- 5. Защитная проверка членства в workspace -----------------------------
if ! cargo metadata --no-deps --format-version 1 2>/dev/null \
     | grep -q '"name":"demo-web-ui"'; then
  echo "⚠️  demo-web-ui is not in workspace members. Adding via python fallback..."
  python3 - <<'PY'
import re, pathlib, sys
p = pathlib.Path("Cargo.toml")
s = p.read_text()
if '"demo-web-ui"' in s:
    print("already present")
    sys.exit(0)
m = re.search(r'members\s*=\s*\[(.*?)\]', s, re.S)
if not m:
    print("ERROR: members array not found", file=sys.stderr)
    sys.exit(1)
inner = m.group(1).rstrip()
if not inner.endswith(','):
    inner += ','
inner += '\n    "demo-web-ui",\n'
p.write_text(s[:m.start()] + 'members = [' + inner + ']' + s[m.end():])
print("added demo-web-ui to workspace members")
PY
else
  echo "✅ demo-web-ui is in workspace members"
fi

# --- 6. Сборка -------------------------------------------------------------
echo
echo "=== cargo check -p demo-web-ui ==="
cargo check -p demo-web-ui

# --- 7. Подсказки на следующий шаг -----------------------------------------
WASM="components/text-engine-component/target/wasm32-wasip1/release/text_engine_component.wasm"
echo
echo "✅ done."
if [ ! -f "$WASM" ]; then
  echo
  echo "⚠️  WASM-компонент ещё не собран:"
  echo "    $WASM"
  echo "    Соберите его перед запуском demo-web-ui:"
  echo "      (cd components/text-engine-component && cargo component build --release)"
fi
echo
echo "Next:"
echo "  (cd components/text-engine-component && cargo component build --release)   # если ещё нет"
echo "  cargo run -p demo-web-ui --release"
echo "  open http://127.0.0.1:3003"