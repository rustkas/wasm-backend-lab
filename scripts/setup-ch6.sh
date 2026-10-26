#!/usr/bin/env bash
# scripts/setup-ch6.sh
#
# Автоматическая настройка Главы 6: Host ↔ Guest boundary.
#
# Создаёт:
#   1. WIT-контракт для нового компонента text-engine-advanced
#   2. Компонент components/text-engine-advanced (string, record, list<u8>, result)
#   3. host/src/runtime_v6.rs (Runtime для нового компонента)
#   4. host/tests/integration_v6.rs (тесты границы, включая negative UTF-8)
#   5. demo-web-ui-ch6/ (визуальный демо-проект, 3 вкладки: String, Record, Bytes)
#
# Не модифицирует существующие компоненты и код из Глав 1–5.
# Идемпотентен: повторный запуск безопасен.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q 'components/text-engine-advanced' Cargo.toml; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if not m:
    raise SystemExit("exclude array not found in Cargo.toml")
inner = m.group(1).rstrip()
if not inner.endswith(','):
    inner += ','
inner += '\n    "components/text-engine-advanced",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-advanced to exclude.")
PY
fi

echo "=== [2/7] WIT contract ==="
mkdir -p wit/text-engine-advanced
cat > wit/text-engine-advanced/world.wit <<'EOF'
package docs:text-engine-advanced@0.1.0;

interface processor {
    record text-request {
        content: string,
        mode: string,
    }

    variant text-error {
        invalid-utf8(string),
        empty-input,
        unknown-mode(string),
    }

    process-string: func(input: string) -> string;
    process-record: func(req: text-request) -> result<string, text-error>;
    process-bytes:  func(data: list<u8>)  -> result<string, text-error>;
}

world text-engine-advanced {
    export processor;
}
EOF

echo "=== [3/7] Guest component ==="
if [ ! -d "components/text-engine-advanced" ]; then
  cargo new components/text-engine-advanced --lib --vcs none >/dev/null
fi
cat > components/text-engine-advanced/Cargo.toml <<'EOF'
[package]
name = "text-engine-advanced"
version = "0.1.0"
edition = "2021"

[workspace]

[lib]
crate-type = ["cdylib"]

[dependencies]
text-engine = { path = "../text-engine" }
wit-bindgen = "0.63"
EOF
cat > components/text-engine-advanced/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine-advanced",
    world: "text-engine-advanced",
});

use exports::docs::text_engine_advanced::processor::{Guest, TextError, TextRequest};

struct AdvancedEngine;

impl Guest for AdvancedEngine {
    fn process_string(input: String) -> String {
        text_engine::normalize_text(&input)
    }

    fn process_record(req: TextRequest) -> Result<String, TextError> {
        if req.content.is_empty() {
            return Err(TextError::EmptyInput);
        }
        match req.mode.as_str() {
            "upper"     => Ok(req.content.to_uppercase()),
            "lower"     => Ok(req.content.to_lowercase()),
            "normalize" => Ok(text_engine::normalize_text(&req.content)),
            other       => Err(TextError::UnknownMode(other.to_string())),
        }
    }

    fn process_bytes(data: Vec<u8>) -> Result<String, TextError> {
        if data.is_empty() {
            return Err(TextError::EmptyInput);
        }
        match String::from_utf8(data) {
            Ok(s)  => Ok(text_engine::normalize_text(&s)),
            Err(e) => Err(TextError::InvalidUtf8(e.to_string())),
        }
    }
}

export!(AdvancedEngine);
EOF

echo "=== [4/7] Host runtime_v6 ==="
cat > host/src/runtime_v6.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use wasmtime::component::{Component, Linker};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine-advanced",
    world: "text-engine-advanced",
});

pub struct MyState {
    ctx: WasiCtx,
    table: wasmtime::component::ResourceTable,
}

impl WasiView for MyState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.ctx, table: &mut self.table }
    }
}

pub struct Runtime {
    engine: Engine,
    component: Component,
    linker: Linker<MyState>,
}

impl Runtime {
    pub fn new(wasm_path: &Path) -> Result<Arc<Self>> {
        if !wasm_path.exists() {
            anyhow::bail!("WASM component not found at `{}`", wasm_path.display());
        }
        let engine = Engine::default();
        let mut linker = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
        let component = Component::from_file(&engine, wasm_path)?;
        Ok(Arc::new(Self { engine, component, linker }))
    }

    pub fn process_string(&self, input: &str) -> Result<String> {
        let mut store = self.new_store();
        let b = TextEngineAdvanced::instantiate(&mut store, &self.component, &self.linker)?;
        Ok(b.docs_text_engine_advanced_processor().call_process_string(&mut store, input)?)
    }

    pub fn process_record(&self, content: &str, mode: &str)
        -> Result<Result<String, String>>
    {
        let mut store = self.new_store();
        let b = TextEngineAdvanced::instantiate(&mut store, &self.component, &self.linker)?;
        let req = exports::docs::text_engine_advanced::processor::TextRequest {
            content: content.to_string(),
            mode: mode.to_string(),
        };
        Ok(b.docs_text_engine_advanced_processor()
            .call_process_record(&mut store, &req)?
            .map_err(|e| format!("{:?}", e)))
    }

    pub fn process_bytes(&self, data: &[u8])
        -> Result<Result<String, String>>
    {
        let mut store = self.new_store();
        let b = TextEngineAdvanced::instantiate(&mut store, &self.component, &self.linker)?;
        Ok(b.docs_text_engine_advanced_processor()
            .call_process_bytes(&mut store, data)?
            .map_err(|e| format!("{:?}", e)))
    }

    fn new_store(&self) -> Store<MyState> {
        let wasi = WasiCtxBuilder::new().build();
        Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        })
    }
}
EOF
if ! grep -q 'pub mod runtime_v6;' host/src/lib.rs; then
  echo 'pub mod runtime_v6;' >> host/src/lib.rs
fi

echo "=== [5/7] Integration tests ==="
cat > host/tests/integration_v6.rs <<'EOF'
use std::path::PathBuf;

fn wasm_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()
        .join("components/text-engine-advanced/target/wasm32-wasip1/release/text_engine_advanced.wasm")
}

#[test]
fn test_v6_data_boundary() {
    let path = wasm_path();
    if !path.exists() {
        eprintln!("Skipping: {} not found.", path.display());
        return;
    }
    let rt = host::runtime_v6::Runtime::new(&path).expect("load");

    // 1. String
    assert_eq!(rt.process_string("  HELLO  ").unwrap(), "hello");

    // 2. Record
    assert_eq!(rt.process_record("  Hi  ", "upper").unwrap().unwrap(), "  HI  ");

    // 3. Empty -> typed error
    let err = rt.process_record("", "upper").unwrap();
    assert!(err.is_err());

    // 4. Unknown mode -> typed error
    let err = rt.process_record("x", "bogus").unwrap();
    assert!(err.is_err());

    // 5. Bytes (valid)
    assert_eq!(rt.process_bytes(b"Hello World").unwrap().unwrap(), "hello world");

    // 6. Bytes (invalid UTF-8) -> typed error, NOT a panic
    let err = rt.process_bytes(&[0xFF, 0xFE, 0xFD]).unwrap();
    assert!(err.is_err());
    assert!(err.unwrap_err().contains("InvalidUtf8"));
}
EOF

echo "=== [6/7] Visual demo (demo-web-ui-ch6) ==="
if [ ! -d "demo-web-ui-ch6" ]; then
  cargo new demo-web-ui-ch6 --bin --vcs none >/dev/null
fi
cat > demo-web-ui-ch6/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch6"
version.workspace = true
edition.workspace = true

[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF
cat > demo-web-ui-ch6/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v6::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process_string(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    match tokio::task::spawn_blocking(move || rt.process_string(&input)).await {
        Ok(Ok(out)) => Json(json!({ "output": out })),
        Ok(Err(e))  => Json(json!({ "error": format!("{e}") })),
        Err(e)      => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn process_record(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let content = p["content"].as_str().unwrap_or("").to_string();
    let mode    = p["mode"].as_str().unwrap_or("").to_string();
    match tokio::task::spawn_blocking(move || rt.process_record(&content, &mode)).await {
        Ok(Ok(Ok(out))) => Json(json!({ "output": out })),
        Ok(Ok(Err(e)))  => {
            eprintln!("[guest-record-error] {e}");
            Json(json!({ "error": "guest_error",
                         "kind":  error_kind(&e),
                         "reason":"see server log for details" }))
        }
        Ok(Err(e))      => Json(json!({ "error": format!("host: {e}") })),
        Err(e)          => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn process_bytes(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let data: Vec<u8> = p["bytes"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_u64().map(|n| n as u8)).collect())
        .unwrap_or_default();
    match tokio::task::spawn_blocking(move || rt.process_bytes(&data)).await {
        Ok(Ok(Ok(out))) => Json(json!({ "output": out })),
        Ok(Ok(Err(e)))  => {
            eprintln!("[guest-bytes-error] {e}");
            Json(json!({ "error": "guest_error",
                         "kind":  error_kind(&e),
                         "reason":"see server log for details" }))
        }
        Ok(Err(e))      => Json(json!({ "error": format!("host: {e}") })),
        Err(e)          => Json(json!({ "error": format!("join: {e}") })),
    }
}

// Извлекаем "kind" из debug-строки TextError::Variant(...)
fn error_kind(debug: &str) -> &'static str {
    if debug.contains("InvalidUtf8")  { "invalid_utf8"  }
    else if debug.contains("EmptyInput")   { "empty_input"   }
    else if debug.contains("UnknownMode")  { "unknown_mode"  }
    else                                   { "unknown"       }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-advanced/target/wasm32-wasip1/release/text_engine_advanced.wasm");

    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!("Run `cd components/text-engine-advanced && cargo component build --release` first.");
        std::process::exit(1);
    }

    println!("Loading component: {}", wasm_path.display());
    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/string", post(process_string))
        .route("/record", post(process_record))
        .route("/bytes",  post(process_bytes))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3005").await?;
    println!("🚀 Demo UI (Ch6): http://127.0.0.1:3005");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

mkdir -p demo-web-ui-ch6/static
cat > demo-web-ui-ch6/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch6: Data Boundary</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0;
          --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444;
          --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       background:var(--bg);color:var(--tx);min-height:100vh;
       display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:880px;width:100%;background:var(--panel);
       border:1px solid var(--br);border-radius:12px;padding:2rem;
       box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem;
     background:linear-gradient(135deg,var(--ac),#a78bfa);
     -webkit-background-clip:text; background-clip:text;
     -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  .sub code{font-family:var(--mo);background:rgba(255,255,255,.05);
            padding:.1rem .35rem;border-radius:4px;color:var(--ac)}
  .tabs{display:flex;gap:.4rem;border-bottom:1px solid var(--br);
        padding-bottom:.5rem;margin-bottom:1.25rem}
  .tab{padding:.55rem 1rem;border-radius:8px;cursor:pointer;
       background:transparent;color:var(--mu);border:1px solid var(--br);
       font-family:var(--mo);font-size:.82rem;transition:.15s}
  .tab:hover{color:var(--tx)}
  .tab.active{background:var(--ac);color:#0c1222;border-color:var(--ac);font-weight:600}
  .panel{display:none}
  .panel.active{display:block}
  label{display:block;font-size:.75rem;font-weight:500;color:var(--mu);
        text-transform:uppercase;letter-spacing:.05em;margin-bottom:.4rem;margin-top:.75rem}
  textarea,input[type=text]{width:100%;padding:.8rem;font-family:var(--mo);
        font-size:.9rem;background:var(--bg);color:var(--tx);
        border:1px solid var(--br);border-radius:8px;outline:none;transition:.15s}
  textarea{min-height:90px;resize:vertical}
  textarea:focus,input[type=text]:focus{border-color:var(--ac)}
  .row{display:grid;grid-template-columns:1fr 1fr;gap:.75rem}
  .actions{display:flex;gap:.6rem;margin-top:1rem;flex-wrap:wrap}
  button{padding:.65rem 1.15rem;font-size:.88rem;font-weight:500;border:none;
         border-radius:8px;cursor:pointer;transition:.15s}
  button.primary{background:var(--ac);color:#0c1222}
  button.primary:hover{background:#0ea5e9}
  button.primary:disabled{opacity:.5;cursor:wait}
  button.danger{background:var(--er);color:#fff}
  button.danger:hover{background:#dc2626}
  .result{margin-top:1.25rem;padding:1rem;background:var(--bg);
          border:1px solid var(--br);border-radius:8px;min-height:70px}
  .result-label{display:flex;justify-content:space-between;
                font-size:.72rem;color:var(--mu);
                text-transform:uppercase;letter-spacing:.05em;margin-bottom:.5rem}
  .result-body{font-family:var(--mo);font-size:.9rem;
               white-space:pre-wrap;word-break:break-word;color:var(--mu)}
  .result-body.ok{color:var(--ok)}
  .result-body.er{color:var(--er)}
  .timing{color:var(--ac);font-family:var(--mo);font-size:.75rem}
</style>
</head>
<body>
<div class="box">
  <h1>Data Boundary: String · Record · Bytes</h1>
  <p class="sub">Passes values through <code>text-engine-advanced.wasm</code> · WIT types & errors</p>

  <div class="tabs">
    <button class="tab active" data-tab="string">String</button>
    <button class="tab" data-tab="record">Record</button>
    <button class="tab" data-tab="bytes">Bytes (list&lt;u8&gt;)</button>
  </div>

  <div class="panel active" id="panel-string">
    <label>Input (string)</label>
    <textarea id="s-in">  Hello   String  </textarea>
    <div class="actions">
      <button class="primary" onclick="runString()">Process → string</button>
    </div>
    <div class="result">
      <div class="result-label"><span>Result</span><span class="timing" id="s-t"></span></div>
      <div class="result-body" id="s-out">Ready.</div>
    </div>
  </div>

  <div class="panel" id="panel-record">
    <div class="row">
      <div>
        <label>Content</label>
        <input type="text" id="r-content" value="  Hello Record  ">
      </div>
      <div>
        <label>Mode (upper / lower / normalize)</label>
        <input type="text" id="r-mode" value="upper">
      </div>
    </div>
    <div class="actions">
      <button class="primary" onclick="runRecord()">Process → result&lt;string, text-error&gt;</button>
      <button class="danger" onclick="runRecordBad()">Send unknown mode</button>
    </div>
    <div class="result">
      <div class="result-label"><span>Result</span><span class="timing" id="r-t"></span></div>
      <div class="result-body" id="r-out">Ready.</div>
    </div>
  </div>

  <div class="panel" id="panel-bytes">
    <label>Input string (converted to UTF-8 bytes in browser)</label>
    <input type="text" id="b-in" value="Hello Bytes">
    <div class="actions">
      <button class="primary" onclick="runBytes(false)">Process → valid UTF-8</button>
      <button class="danger" onclick="runBytes(true)">Send invalid UTF-8 (0xFF 0xFE 0xFD)</button>
    </div>
    <div class="result">
      <div class="result-label"><span>Result</span><span class="timing" id="b-t"></span></div>
      <div class="result-body" id="b-out">Ready.</div>
    </div>
  </div>
</div>

<script>
const tabs = document.querySelectorAll('.tab');
tabs.forEach(t => t.onclick = () => {
  tabs.forEach(x => x.classList.remove('active'));
  t.classList.add('active');
  document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
  document.getElementById('panel-' + t.dataset.tab).classList.add('active');
});

async function post(url, body) {
  const t0 = performance.now();
  const r = await fetch(url, { method:'POST', headers:{'Content-Type':'application/json'},
                                body: JSON.stringify(body) });
  const data = await r.json();
  return { data, ms: performance.now() - t0 };
}

function show(outEl, timingEl, r) {
  timingEl.textContent = 'round-trip: ' + r.ms.toFixed(2) + ' ms';
  if (r.data.error) {
    outEl.className = 'result-body er';
    outEl.textContent = 'Error [' + (r.data.kind || r.data.error) + ']: ' + (r.data.reason || '');
  } else {
    outEl.className = 'result-body ok';
    outEl.textContent = r.data.output === '' ? '(empty string)' : r.data.output;
  }
}

async function runString() {
  const o = document.getElementById('s-out'), t = document.getElementById('s-t');
  o.textContent = 'Calling…';
  try { show(o, t, await post('/string', { input: document.getElementById('s-in').value })); }
  catch(e) { o.className='result-body er'; o.textContent = e; }
}

async function runRecord() {
  const o = document.getElementById('r-out'), t = document.getElementById('r-t');
  o.textContent = 'Calling…';
  try { show(o, t, await post('/record', {
    content: document.getElementById('r-content').value,
    mode:    document.getElementById('r-mode').value
  })); } catch(e) { o.className='result-body er'; o.textContent = e; }
}

async function runRecordBad() {
  document.getElementById('r-mode').value = 'bogus_mode';
  await runRecord();
}

async function runBytes(invalid) {
  const o = document.getElementById('b-out'), t = document.getElementById('b-t');
  o.textContent = 'Calling…';
  const bytes = invalid
    ? [255, 254, 253]
    : Array.from(new TextEncoder().encode(document.getElementById('b-in').value));
  try { show(o, t, await post('/bytes', { bytes })); }
  catch(e) { o.className='result-body err'; o.textContent = e; }
}
</script>
</body>
</html>
HTML_EOF

echo "=== [7/7] Build & verify ==="
(cd components/text-engine-advanced && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch6 --quiet

echo
echo "✅ Готово. Следующие шаги:"
echo "  1. Собрать компонент:  (cd components/text-engine-advanced && cargo component build --release)"
echo "  2. Тесты:              (cd host && cargo test --test integration_v6)"
echo "  3. Демо:               cargo run -p demo-web-ui-ch6 --release"
echo "  4. Открыть:            http://127.0.0.1:3005"