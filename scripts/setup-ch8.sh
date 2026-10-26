#!/usr/bin/env bash
# scripts/setup-ch8.sh
#
# Автоматическая настройка Главы 8: Time control: fuel, epoch, cancellation.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q 'components/text-engine-hang' Cargo.toml; then
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
inner += '\n    "components/text-engine-hang",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-hang to exclude.")
PY
fi

echo "=== [2/7] WIT contract ==="
mkdir -p wit/text-engine-hang
rm -f wit/text-engine-hang/world.wit
sleep 0.1
cat > wit/text-engine-hang/world.wit <<'EOF'
package docs:text-engine-hang@0.1.0;
interface processor {
    process: func(iterations: u32) -> string;
}
world text-engine-hang {
    export processor;
}
EOF

echo "=== [3/7] Guest component ==="
if [ ! -d "components/text-engine-hang" ]; then
  cargo new components/text-engine-hang --lib --vcs none >/dev/null
fi
rm -f components/text-engine-hang/Cargo.toml components/text-engine-hang/src/lib.rs
sleep 0.1
cat > components/text-engine-hang/Cargo.toml <<'EOF'
[package]
name = "text-engine-hang"
version = "0.1.0"
edition = "2021"
[workspace]
[lib]
crate-type = ["cdylib"]
[dependencies]
wit-bindgen = "0.63"
EOF
cat > components/text-engine-hang/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine-hang",
    world: "text-engine-hang",
});
use exports::docs::text_engine_hang::processor::Guest;
struct HangEngine;
impl Guest for HangEngine {
    fn process(iterations: u32) -> String {
        if iterations == 0 {
            let mut i: u64 = 0;
            loop {
                i = i.wrapping_add(1);
                std::hint::black_box(i);
            }
        } else {
            let mut sum: u64 = 0;
            for i in 0..iterations {
                sum = sum.wrapping_add(i as u64);
                std::hint::black_box(sum);
            }
            format!("Completed {} iterations, sum={}", iterations, sum)
        }
    }
}
export!(HangEngine);
EOF

echo "=== [4/7] Host runtime_v8 ==="
rm -f host/src/runtime_v8.rs
sleep 0.1
cat > host/src/runtime_v8.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use wasmtime::component::{Component, Linker};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine-hang",
    world: "text-engine-hang",
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
        let mut config = Config::new();
        config.consume_fuel(true);
        config.epoch_interruption(true);
        let engine = Engine::new(&config)?;
        
        let mut linker = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
        let component = Component::from_file(&engine, wasm_path)?;

        let engine_clone = engine.clone();
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(50));
                engine_clone.increment_epoch();
            }
        });
        Ok(Arc::new(Self { engine, component, linker }))
    }

    fn new_store(&self) -> Store<MyState> {
        let wasi = WasiCtxBuilder::new().build();
        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });
        // Важно: не используем u64::MAX из-за бага переполнения в Wasmtime 49
        store.set_epoch_deadline(1_000_000);
        let _ = store.set_fuel(u64::MAX);
        store
    }

    pub fn run_with_fuel(&self, iterations: u32, fuel_limit: u64) -> Result<String> {
        let mut store = self.new_store();
        store.set_fuel(fuel_limit)?;
        let b = TextEngineHang::instantiate(&mut store, &self.component, &self.linker)?;
        Ok(b.docs_text_engine_hang_processor().call_process(&mut store, iterations)?)
    }

    pub fn run_with_epoch(&self, iterations: u32) -> Result<String> {
        let mut store = self.new_store();
        store.set_epoch_deadline(2); // 2 * 50ms = 100ms
        let b = TextEngineHang::instantiate(&mut store, &self.component, &self.linker)?;
        Ok(b.docs_text_engine_hang_processor().call_process(&mut store, iterations)?)
    }
}
EOF

if ! grep -q 'pub mod runtime_v8;' host/src/lib.rs; then
  echo 'pub mod runtime_v8;' >> host/src/lib.rs
fi
touch host/src/lib.rs

echo "=== [5/7] Integration tests ==="
rm -f host/tests/integration_v8.rs
sleep 0.1
cat > host/tests/integration_v8.rs <<'EOF'
use std::path::PathBuf;
fn wasm_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap()
        .join("components/text-engine-hang/target/wasm32-wasip1/release/text_engine_hang.wasm")
}
#[test]
fn test_v8_time_limits() {
    let path = wasm_path();
    if !path.exists() { eprintln!("Skipping"); return; }
    let rt = host::runtime_v8::Runtime::new(&path).expect("load");

    // 1. Успешный запуск
    let res = rt.run_with_fuel(1000, 10_000_000_000);
    assert!(res.is_ok(), "Should complete: {:?}", res.err());

    // 2. Нехватка fuel
    let err = rt.run_with_fuel(0, 1_000_000).unwrap_err();
    assert!(format!("{:?}", err).contains("fuel"), "Expected fuel trap");

    // 3. Epoch
    let err = rt.run_with_epoch(0).unwrap_err();
    assert!(format!("{:?}", err).contains("interrupt"), "Expected epoch trap");
}
EOF

echo "=== [6/7] Visual demo (demo-web-ui-ch8) ==="
if [ ! -d "demo-web-ui-ch8" ]; then
  cargo new demo-web-ui-ch8 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch8/Cargo.toml demo-web-ui-ch8/src/main.rs
mkdir -p demo-web-ui-ch8/static
rm -f demo-web-ui-ch8/static/index.html
sleep 0.1
cat > demo-web-ui-ch8/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch8"
version.workspace = true
edition.workspace = true
[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF

cat > demo-web-ui-ch8/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v8::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

fn format_err(e: anyhow::Error) -> String {
    let s = format!("{e:?}");
    if s.contains("interrupt") { "Error: Timeout (Epoch interrupted)".to_string() }
    else if s.contains("fuel") { "Error: Fuel exhausted".to_string() }
    else { format!("Error: {}", s) }
}

async fn run_fuel(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let iterations = p["iterations"].as_u64().unwrap_or(0) as u32;
    let start = std::time::Instant::now();
    match tokio::task::spawn_blocking(move || rt.run_with_fuel(iterations, 100_000_000)).await {
        Ok(Ok(out)) => Json(json!({ "output": out, "time_ms": start.elapsed().as_millis() })),
        Ok(Err(e))  => Json(json!({ "error": format_err(e), "time_ms": start.elapsed().as_millis() })),
        Err(e)      => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

async fn run_epoch(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let iterations = p["iterations"].as_u64().unwrap_or(0) as u32;
    let start = std::time::Instant::now();
    match tokio::task::spawn_blocking(move || rt.run_with_epoch(iterations)).await {
        Ok(Ok(out)) => Json(json!({ "output": out, "time_ms": start.elapsed().as_millis() })),
        Ok(Err(e))  => Json(json!({ "error": format_err(e), "time_ms": start.elapsed().as_millis() })),
        Err(e)      => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

async fn run_no_limit(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let iterations = p["iterations"].as_u64().unwrap_or(0) as u32;
    let start = std::time::Instant::now();
    // 10 миллиардов топлива — это надолго зависнет
    match tokio::task::spawn_blocking(move || rt.run_with_fuel(iterations, 10_000_000_000)).await {
        Ok(Ok(out)) => Json(json!({ "output": out, "time_ms": start.elapsed().as_millis() })),
        Ok(Err(e))  => Json(json!({ "error": format_err(e), "time_ms": start.elapsed().as_millis() })),
        Err(e)      => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-hang/target/wasm32-wasip1/release/text_engine_hang.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/run_fuel", post(run_fuel))
        .route("/run_epoch", post(run_epoch))
        .route("/run_no_limit", post(run_no_limit))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3007").await?;
    println!("🚀 Demo UI (Ch8): http://127.0.0.1:3007");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

# CSS и HTML оставляем без изменений (они были нормальные), 
# только немного поправим текст в кнопке "No Limits"
cat > demo-web-ui-ch8/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch8: Time Control</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0; --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444; --wr:#f59e0b; --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg);color:var(--tx);min-height:100vh; display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:900px;width:100%;background:var(--panel); border:1px solid var(--br);border-radius:12px;padding:2rem; box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem; background:linear-gradient(135deg,var(--ac),#a78bfa); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  .controls { display: flex; gap: 1rem; align-items: flex-end; margin-bottom: 2rem; justify-content: center; }
  .control-group { display: flex; flex-direction: column; gap: .5rem; }
  label { font-size: .8rem; color: var(--mu); text-transform: uppercase; }
  input { background: var(--bg); border: 1px solid var(--br); color: var(--tx); padding: .5rem; border-radius: 6px; width: 120px; font-family: var(--mo); }
  .grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1rem; }
  .panel { background: var(--bg); border: 1px solid var(--br); border-radius: 8px; padding: 1.25rem; text-align: center; display: flex; flex-direction: column; }
  h2 { font-size: .9rem; font-weight: 600; margin-bottom: .5rem; color: var(--ac); }
  .desc { font-size: .75rem; color: var(--mu); margin-bottom: 1rem; flex-grow: 1; }
  button { padding: .6rem 1rem; font-size: .85rem; font-weight: 500; border: none; border-radius: 6px; cursor: pointer; transition: .15s; width: 100%; }
  button.bad { background: var(--er); color: white; }
  button.good { background: var(--ac); color: #0c1222; }
  button.warn { background: var(--wr); color: #0c1222; }
  button:hover { filter: brightness(1.1); }
  button:disabled { opacity: .5; cursor: wait; }
  .result { margin-top: 1rem; font-family: var(--mo); font-size: .75rem; word-break: break-all; min-height: 40px; }
  .res-ok { color: var(--ok); }
  .res-err { color: var(--er); }
  .time { color: var(--ac); font-size: .7rem; margin-top: .5rem; }
</style>
</head>
<body>
<div class="box">
  <h1>Time Control: Fuel vs Epoch</h1>
  <p class="sub">Защита backend от бесконечных циклов</p>

  <div class="controls">
    <div class="control-group">
      <label>Iterations (0 = Infinite)</label>
      <input type="number" id="iterations" value="0" min="0" step="1000">
    </div>
  </div>

  <div class="grid">
    <div class="panel">
      <h2>No Epoch Limit (Danger)</h2>
      <p class="desc">10 млрд топлива, но нет прерывания по времени. При 0 — сервер зависнет на секунды.</p>
      <button class="bad" onclick="run('/run_no_limit')">Run No Limit</button>
      <div class="result" id="out-no"></div>
    </div>

    <div class="panel">
      <h2>Fuel Limit</h2>
      <p class="desc">100 млн инструкций. Тратит CPU на проверку.</p>
      <button class="good" onclick="run('/run_fuel')">Run with Fuel</button>
      <div class="result" id="out-fuel"></div>
    </div>

    <div class="panel">
      <h2>Epoch Limit</h2>
      <p class="desc">Прерывание по таймеру (100 мс). Эффективнее.</p>
      <button class="warn" onclick="run('/run_epoch')">Run with Epoch</button>
      <div class="result" id="out-epoch"></div>
    </div>
  </div>
</div>

<script>
async function run(url) {
  const iter = parseInt(document.getElementById('iterations').value);
  const id = url.split('_')[1];
  const out = document.getElementById('out-' + id);
  out.innerHTML = 'Running...'; out.className = 'result';
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  try {
    const res = await fetch(url, { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ iterations: iter }) });
    const data = await res.json();
    if (data.error) { out.innerHTML = `<span class="res-err">${data.error}</span>`; }
    else { out.innerHTML = `<span class="res-ok">${data.output}</span>`; }
    if (data.time_ms !== undefined) { out.innerHTML += `<div class="time">Time: ${data.time_ms} ms</div>`; }
  } catch (e) {
    out.innerHTML = `<span class="res-err">Network error: ${e}</span>`;
  } finally {
    document.querySelectorAll('button').forEach(b => b.disabled = false);
  }
}
</script>
</body>
</html>
HTML_EOF

echo "=== [7/7] Build & verify ==="
(cd components/text-engine-hang && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch8 --quiet
echo "✅ Готово. Запустите тесты: (cd host && cargo test --test integration_v8)"