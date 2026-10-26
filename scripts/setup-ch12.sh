#!/usr/bin/env bash
# scripts/setup-ch12.sh
#
# Автоматическая настройка Главы 12: Observability (logs, metrics).
#
# Создаёт:
#   1. WIT-контракт для компонента text-engine-observe.
#   2. Компонент components/text-engine-observe (пишет в stdout).
#   3. host/src/runtime_v12.rs (Runtime с MemoryOutputPipe и замером времени).
#   4. host/tests/integration_v12.rs (тесты логов и метрик).
#   5. demo-web-ui-ch12/ (визуальный демо-проект).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q 'components/text-engine-observe' Cargo.toml; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if not m: raise SystemExit("exclude array not found")
inner = m.group(1).rstrip()
if not inner.endswith(','): inner += ','
inner += '\n    "components/text-engine-observe",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-observe to exclude.")
PY
fi

echo "=== [2/7] WIT contract ==="
mkdir -p wit/text-engine-observe
rm -f wit/text-engine-observe/world.wit
sleep 0.1
cat > wit/text-engine-observe/world.wit <<'EOF'
package docs:text-engine-observe@0.1.0;
interface processor {
    process: func(input: string) -> string;
}
world text-engine-observe {
    export processor;
}
EOF

echo "=== [3/7] Guest component ==="
if [ ! -d "components/text-engine-observe" ]; then
  cargo new components/text-engine-observe --lib --vcs none >/dev/null
fi
rm -f components/text-engine-observe/Cargo.toml components/text-engine-observe/src/lib.rs
sleep 0.1
cat > components/text-engine-observe/Cargo.toml <<'EOF'
[package]
name = "text-engine-observe"
version = "0.1.0"
edition = "2021"
[workspace]
[lib]
crate-type = ["cdylib"]
[dependencies]
wit-bindgen = "0.63"
EOF
cat > components/text-engine-observe/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine-observe",
    world: "text-engine-observe",
});

use exports::docs::text_engine_observe::processor::Guest;

struct ObserveEngine;

impl Guest for ObserveEngine {
    fn process(input: String) -> String {
        // В WASI эти вызовы перехватываются Host-ом
        println!("[guest-log] Starting processing");
        println!("[guest-log] Input length: {}", input.len());
        
        let result = input.to_uppercase();
        
        println!("[guest-log] Finished processing successfully");
        result
    }
}
export!(ObserveEngine);
EOF

echo "=== [4/7] Host runtime_v12 ==="
rm -f host/src/runtime_v12.rs
sleep 0.1
cat > host/src/runtime_v12.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use wasmtime::component::{Component, Linker};
use wasmtime::{Engine, Store};
use wasmtime_wasi::p2::pipe::MemoryOutputPipe;
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine-observe",
    world: "text-engine-observe",
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

pub struct ObservedResult {
    pub output: String,
    pub logs: String,
    pub duration: Duration,
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

    pub fn process_observed(&self, input: &str) -> Result<ObservedResult> {
        let stdout_pipe = MemoryOutputPipe::new(8192);
        
        let wasi = WasiCtxBuilder::new()
            .stdout(stdout_pipe.clone())
            .build();

        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });

        let b = TextEngineObserve::instantiate(&mut store, &self.component, &self.linker)?;
        
        let start = Instant::now();
        let res = b.docs_text_engine_observe_processor().call_process(&mut store, input)?;
        let duration = start.elapsed();

        let logs_bytes = stdout_pipe.contents();
        let logs = String::from_utf8_lossy(&logs_bytes).to_string();

        Ok(ObservedResult { output: res, logs, duration })
    }
}
EOF

if ! grep -q 'pub mod runtime_v12;' host/src/lib.rs; then
  echo 'pub mod runtime_v12;' >> host/src/lib.rs
fi
touch host/src/lib.rs

echo "=== [5/7] Integration tests ==="
rm -f host/tests/integration_v12.rs
sleep 0.1
cat > host/tests/integration_v12.rs <<'EOF'
use std::path::PathBuf;

fn wasm_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap()
        .join("components/text-engine-observe/target/wasm32-wasip1/release/text_engine_observe.wasm")
}

#[test]
fn test_v12_observability() {
    let path = wasm_path();
    if !path.exists() { eprintln!("Skipping"); return; }
    let rt = host::runtime_v12::Runtime::new(&path).expect("load");

    let res = rt.process_observed("hello world").expect("process");
    
    // 1. Проверяем корректность бизнес-логики
    assert_eq!(res.output, "HELLO WORLD");

    // 2. Проверяем, что логи были перехвачены
    assert!(res.logs.contains("[guest-log] Starting processing"));
    assert!(res.logs.contains("[guest-log] Input length: 11"));
    assert!(res.logs.contains("[guest-log] Finished processing successfully"));

    // 3. Проверяем, что время выполнения замерено (больше 0)
    assert!(res.duration.as_nanos() > 0);
}
EOF

echo "=== [6/7] Visual demo (demo-web-ui-ch12) ==="
if [ ! -d "demo-web-ui-ch12" ]; then
  cargo new demo-web-ui-ch12 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch12/Cargo.toml demo-web-ui-ch12/src/main.rs
mkdir -p demo-web-ui-ch12/static
rm -f demo-web-ui-ch12/static/index.html
sleep 0.1
cat > demo-web-ui-ch12/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch12"
version.workspace = true
edition.workspace = true
[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF
cat > demo-web-ui-ch12/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v12::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Json(p): Json<Value>) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    
    match tokio::task::spawn_blocking(move || rt.process_observed(&input)).await {
        Ok(Ok(res)) => Json(json!({
            "output": res.output,
            "logs": res.logs,
            "metrics": {
                "duration_us": res.duration.as_micros(),
                "duration_ms": res.duration.as_secs_f64() * 1000.0
            }
        })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-observe/target/wasm32-wasip1/release/text_engine_observe.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/process", post(process))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3011").await?;
    println!("🚀 Demo UI (Ch12): http://127.0.0.1:3011");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > demo-web-ui-ch12/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch12: Observability</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0; --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444; --wr:#f59e0b; --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg);color:var(--tx);min-height:100vh; display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:900px;width:100%;background:var(--panel); border:1px solid var(--br);border-radius:12px;padding:2rem; box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem; background:linear-gradient(135deg,var(--ac),#a78bfa); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  .input-row { display: flex; gap: 1rem; margin-bottom: 1.5rem; }
  input[type=text] { flex-grow: 1; padding: .8rem; background: var(--bg); border: 1px solid var(--br); color: var(--tx); border-radius: 8px; font-family: var(--mo); }
  button { padding: .8rem 1.5rem; background: var(--ac); color: #0c1222; border: none; border-radius: 8px; font-weight: 600; cursor: pointer; transition: .15s; }
  button:hover { filter: brightness(1.1); }
  button:disabled { opacity: .5; cursor: wait; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
  .panel { background: var(--bg); border: 1px solid var(--br); border-radius: 8px; padding: 1.25rem; }
  h2 { font-size: .85rem; font-weight: 600; margin-bottom: .5rem; color: var(--ac); text-transform: uppercase; letter-spacing: .05em; }
  .logs { grid-column: span 2; background: #000; border-radius: 8px; padding: 1rem; font-family: var(--mo); font-size: .8rem; color: #a3e635; min-height: 120px; white-space: pre-wrap; }
  .metric-val { font-family: var(--mo); font-size: 1.5rem; color: var(--ok); margin-top: 0.5rem; }
</style>
</head>
<body>
<div class="box">
  <h1>Observability: Logs & Metrics</h1>
  <p class="sub">Capturing guest stdout and measuring execution time</p>

  <div class="input-row">
    <input type="text" id="input" value="  Hello   WASM  ">
    <button id="btn" onclick="run()">Process</button>
  </div>

  <div class="grid">
    <div class="panel">
      <h2>Result</h2>
      <div class="metric-val" id="out-result" style="font-size:1rem">-</div>
    </div>
    <div class="panel">
      <h2>Metrics (Duration)</h2>
      <div class="metric-val" id="out-metrics">-</div>
    </div>
    <div class="logs" id="out-logs">Awaiting guest logs...</div>
  </div>
</div>
<script>
async function run() {
  const btn = document.getElementById('btn');
  btn.disabled = true;
  document.getElementById('out-result').innerHTML = 'Processing...';
  document.getElementById('out-metrics').innerHTML = '-';
  document.getElementById('out-logs').innerHTML = 'Waiting...';

  try {
    const res = await fetch('/process', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ input: document.getElementById('input').value })
    });
    const data = await res.json();
    
    if (data.error) {
      document.getElementById('out-result').innerHTML = `<span style="color:var(--er)">Error</span>`;
      document.getElementById('out-logs').innerHTML = data.error;
    } else {
      document.getElementById('out-result').textContent = data.output;
      document.getElementById('out-metrics').textContent = `${data.metrics.duration_us} µs`;
      document.getElementById('out-logs').textContent = data.logs || '(no logs)';
    }
  } catch (e) {
    document.getElementById('out-logs').textContent = 'Network error: ' + e;
  } finally {
    btn.disabled = false;
  }
}
</script>
</body>
</html>
HTML_EOF

echo "=== [7/7] Build & verify ==="
(cd components/text-engine-observe && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch12 --quiet

echo "✅ Готово. Следующие шаги:"
echo "  1. Тесты:  (cd host && cargo test --test integration_v12)"
echo "  2. Демо:   cargo run -p demo-web-ui-ch12 --release"
echo "  3. Открыть: http://127.0.0.1:3011"