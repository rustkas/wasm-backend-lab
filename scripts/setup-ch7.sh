#!/usr/bin/env bash
# scripts/setup-ch7.sh
#
# Автоматическая настройка Главы 7: State: operational model and ownership.
# 
# ВАЖНО: Для синхронизации с rust-analyzer скрипт принудительно удаляет
# старые файлы перед созданием новых и делает touch host/src/lib.rs.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q 'components/text-engine-stateful' Cargo.toml; then
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
inner += '\n    "components/text-engine-stateful",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-stateful to exclude.")
PY
fi

echo "=== [2/7] WIT contract ==="
mkdir -p wit/text-engine-stateful
rm -f wit/text-engine-stateful/world.wit
sleep 0.1
cat > wit/text-engine-stateful/world.wit <<'EOF'
package docs:text-engine-stateful@0.1.0;

interface processor {
    increment: func() -> u32;
    get: func() -> u32;
    reset: func();
}

world text-engine-stateful {
    export processor;
}
EOF

echo "=== [3/7] Guest component ==="
if [ ! -d "components/text-engine-stateful" ]; then
  cargo new components/text-engine-stateful --lib --vcs none >/dev/null
fi
rm -f components/text-engine-stateful/Cargo.toml components/text-engine-stateful/src/lib.rs
sleep 0.1

cat > components/text-engine-stateful/Cargo.toml <<'EOF'
[package]
name = "text-engine-stateful"
version = "0.1.0"
edition = "2021"

[workspace]

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = "0.63"
EOF

cat > components/text-engine-stateful/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine-stateful",
    world: "text-engine-stateful",
});

use exports::docs::text_engine_stateful::processor::Guest;
use std::sync::atomic::{AtomicU32, Ordering};

// Глобальное состояние в WASM linear memory.
// Оно сохраняется до тех пор, пока жив Store (и инстанс компонента).
static COUNTER: AtomicU32 = AtomicU32::new(0);

struct StatefulEngine;

impl Guest for StatefulEngine {
    fn increment() -> u32 {
        COUNTER.fetch_add(1, Ordering::SeqCst) + 1
    }

    fn get() -> u32 {
        COUNTER.load(Ordering::SeqCst)
    }

    fn reset() {
        COUNTER.store(0, Ordering::SeqCst);
    }
}

export!(StatefulEngine);
EOF

echo "=== [4/7] Host runtime_v7 ==="
rm -f host/src/runtime_v7.rs
sleep 0.1

cat > host/src/runtime_v7.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::{Arc, Mutex};
use wasmtime::component::{Component, Linker};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine-stateful",
    world: "text-engine-stateful",
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
    // Сохраняем Store И инстанцированный компонент (bindings).
    // Если мы будем вызывать instantiate при каждом запросе, 
    // Wasmtime создаст новый Instance со свежей памятью, и состояние сбросится.
    stateful: Mutex<(Store<MyState>, TextEngineStateful)>,
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

        let wasi = WasiCtxBuilder::new().build();
        let mut store = Store::new(&engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });
        
        // Инстанцируем ОДИН раз при создании Runtime.
        let bindings = TextEngineStateful::instantiate(&mut store, &component, &linker)?;

        Ok(Arc::new(Self {
            engine,
            component,
            linker,
            stateful: Mutex::new((store, bindings)),
        }))
    }

    /// Stateless: создаёт новый Store и Instance на каждый вызов.
    pub fn increment_stateless(&self) -> Result<u32> {
        let wasi = WasiCtxBuilder::new().build();
        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });
        let b = TextEngineStateful::instantiate(&mut store, &self.component, &self.linker)?;
        Ok(b.docs_text_engine_stateful_processor().call_increment(&mut store)?)
    }

    /// Stateful: использует уже готовые bindings и Store. Счётчик растёт.
    pub fn increment_stateful(&self) -> Result<u32> {
        let mut guard = self.stateful.lock().unwrap();
        let (store, bindings) = &mut *guard;
        Ok(bindings.docs_text_engine_stateful_processor().call_increment(store)?)
    }

    pub fn get_stateful(&self) -> Result<u32> {
        let mut guard = self.stateful.lock().unwrap();
        let (store, bindings) = &mut *guard;
        Ok(bindings.docs_text_engine_stateful_processor().call_get(store)?)
    }

    pub fn reset_stateful(&self) -> Result<()> {
        let mut guard = self.stateful.lock().unwrap();
        let (store, bindings) = &mut *guard;
        bindings.docs_text_engine_stateful_processor().call_reset(store)?;
        Ok(())
    }
}
EOF

if ! grep -q 'pub mod runtime_v7;' host/src/lib.rs; then
  echo 'pub mod runtime_v7;' >> host/src/lib.rs
fi
# Принудительно обновляем mtime lib.rs для rust-analyzer
touch host/src/lib.rs

echo "=== [5/7] Integration tests ==="
rm -f host/tests/integration_v7.rs
sleep 0.1

cat > host/tests/integration_v7.rs <<'EOF'
use std::path::PathBuf;

fn wasm_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()
        .join("components/text-engine-stateful/target/wasm32-wasip1/release/text_engine_stateful.wasm")
}

#[test]
fn test_v7_state_model() {
    let path = wasm_path();
    if !path.exists() {
        eprintln!("Skipping: {} not found.", path.display());
        return;
    }
    let rt = host::runtime_v7::Runtime::new(&path).expect("load");

    // 1. Stateless: каждый вызов сбрасывает состояние
    assert_eq!(rt.increment_stateless().unwrap(), 1);
    assert_eq!(rt.increment_stateless().unwrap(), 1);

    // 2. Stateful: состояние сохраняется
    rt.reset_stateful().unwrap();
    assert_eq!(rt.increment_stateful().unwrap(), 1);
    assert_eq!(rt.increment_stateful().unwrap(), 2);
    assert_eq!(rt.get_stateful().unwrap(), 2);

    // 3. Сброс
    rt.reset_stateful().unwrap();
    assert_eq!(rt.get_stateful().unwrap(), 0);
}
EOF

echo "=== [6/7] Visual demo (demo-web-ui-ch7) ==="
if [ ! -d "demo-web-ui-ch7" ]; then
  cargo new demo-web-ui-ch7 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch7/Cargo.toml demo-web-ui-ch7/src/main.rs
mkdir -p demo-web-ui-ch7/static
rm -f demo-web-ui-ch7/static/index.html
sleep 0.1

cat > demo-web-ui-ch7/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch7"
version.workspace = true
edition.workspace = true

[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF

cat > demo-web-ui-ch7/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v7::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn stateless_increment(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.increment_stateless()).await {
        Ok(Ok(val)) => Json(json!({ "value": val })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn stateful_increment(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.increment_stateful()).await {
        Ok(Ok(val)) => Json(json!({ "value": val })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn stateful_get(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.get_stateful()).await {
        Ok(Ok(val)) => Json(json!({ "value": val })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn stateful_reset(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.reset_stateful()).await {
        Ok(Ok(())) => Json(json!({ "status": "reset" })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-stateful/target/wasm32-wasip1/release/text_engine_stateful.wasm");

    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!("Run `cd components/text-engine-stateful && cargo component build --release` first.");
        std::process::exit(1);
    }

    println!("Loading component: {}", wasm_path.display());
    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/stateless/increment", post(stateless_increment))
        .route("/stateful/increment", post(stateful_increment))
        .route("/stateful/get", get(stateful_get))
        .route("/stateful/reset", post(stateful_reset))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3006").await?;
    println!("🚀 Demo UI (Ch7): http://127.0.0.1:3006");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > demo-web-ui-ch7/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch7: State Model</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0;
          --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444;
          --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       background:var(--bg);color:var(--tx);min-height:100vh;
       display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:900px;width:100%;background:var(--panel);
       border:1px solid var(--br);border-radius:12px;padding:2rem;
       box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem;
     background:linear-gradient(135deg,var(--ac),#a78bfa);
     -webkit-background-clip:text; background-clip:text;
     -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:1.5rem}
  .panel{background:var(--bg);border:1px solid var(--br);border-radius:8px;padding:1.25rem}
  h2{font-size:1rem;font-weight:600;margin-bottom:1rem;color:var(--ac);text-align:center}
  .val{font-size:2.5rem;font-family:var(--mo);text-align:center;margin:1rem 0;color:var(--ok)}
  .actions{display:flex;gap:.5rem;flex-wrap:wrap;justify-content:center}
  button{padding:.6rem 1rem;font-size:.85rem;font-weight:500;border:none;
         border-radius:6px;cursor:pointer;transition:.15s}
  button.primary{background:var(--ac);color:#0c1222}
  button.primary:hover{background:#0ea5e9}
  button.secondary{background:transparent;color:var(--mu);border:1px solid var(--br)}
  button.secondary:hover{color:var(--tx);border-color:var(--ac)}
  .note{margin-top:1.5rem;padding:1rem;background:rgba(56,189,248,0.1);
        border-left:3px solid var(--ac);border-radius:4px;font-size:.85rem;color:var(--mu)}
  code{font-family:var(--mo);background:rgba(255,255,255,0.05);padding:.1rem .3rem;border-radius:3px}
</style>
</head>
<body>
<div class="box">
  <h1>State: Operational Model</h1>
  <p class="sub">Store lifecycle and WASM linear memory</p>

  <div class="grid">
    <div class="panel">
      <h2>Stateless</h2>
      <p style="font-size:.75rem;color:var(--mu);text-align:center;margin-bottom:.5rem">
        New <code>Store</code> per request
      </p>
      <div class="val" id="s-val">0</div>
      <div class="actions">
        <button class="primary" onclick="incStateless()">Increment</button>
      </div>
    </div>

    <div class="panel">
      <h2>Stateful</h2>
      <p style="font-size:.75rem;color:var(--mu);text-align:center;margin-bottom:.5rem">
        Shared <code>Store</code> behind <code>Mutex</code>
      </p>
      <div class="val" id="st-val">0</div>
      <div class="actions">
        <button class="primary" onclick="incStateful()">Increment</button>
        <button class="secondary" onclick="resetStateful()">Reset</button>
      </div>
    </div>
  </div>

  <div class="note">
    <b>Why this matters:</b> The stateless panel always returns 1 because each call creates a fresh
    <code>Store</code> and instantiates the component from scratch. WASM memory is wiped. The stateful
    panel keeps the <code>Store</code> alive, so the atomic counter inside the component's linear memory
    survives between HTTP requests.
  </div>
</div>

<script>
async function post(url) {
  const r = await fetch(url, { method: 'POST' });
  return await r.json();
}
async function get(url) {
  const r = await fetch(url);
  return await r.json();
}

async function incStateless() {
  const data = await post('/stateless/increment');
  document.getElementById('s-val').textContent = data.value ?? 'err';
}

async function incStateful() {
  const data = await post('/stateful/increment');
  document.getElementById('st-val').textContent = data.value ?? 'err';
}

async function resetStateful() {
  await post('/stateful/reset');
  const data = await get('/stateful/get');
  document.getElementById('st-val').textContent = data.value ?? 'err';
}

// Initial fetch
get('/stateful/get').then(d => {
  if (d.value !== undefined) document.getElementById('st-val').textContent = d.value;
});
</script>
</body>
</html>
HTML_EOF

echo "=== [7/7] Build & verify ==="
(cd components/text-engine-stateful && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch7 --quiet

echo
echo "✅ Готово. Следующие шаги:"
echo "  1. Собрать компонент:  (cd components/text-engine-stateful && cargo component build --release)"
echo "  2. Тесты:              (cd host && cargo test --test integration_v7)"
echo "  3. Демо:               cargo run -p demo-web-ui-ch7 --release"
echo "  4. Открыть:            http://127.0.0.1:3006"