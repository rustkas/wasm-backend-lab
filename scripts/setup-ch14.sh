#!/usr/bin/env bash
# scripts/setup-ch14.sh
#
# Автоматическая настройка Главы 14: Streams and the memory path.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q 'components/text-engine-stream' Cargo.toml; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if not m: raise SystemExit("exclude array not found")
inner = m.group(1).rstrip()
if not inner.endswith(','): inner += ','
inner += '\n    "components/text-engine-stream",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-stream to exclude.")
PY
fi

echo "=== [2/7] WIT contract ==="
mkdir -p wit/text-engine-stream
rm -f wit/text-engine-stream/world.wit
sleep 0.1
cat > wit/text-engine-stream/world.wit <<'EOF'
package docs:text-engine-stream@0.1.0;

interface processor {
    process-list: func(data: list<u8>) -> u32;

    resource chunk-reader {
        read-chunk: func() -> option<list<u8>>;
    }
    open-reader: func(total-size: u32) -> chunk-reader;
}

world text-engine-stream {
    export processor;
}
EOF

echo "=== [3/7] Guest component ==="
if [ ! -d "components/text-engine-stream" ]; then
  cargo new components/text-engine-stream --lib --vcs none >/dev/null
fi
rm -f components/text-engine-stream/Cargo.toml components/text-engine-stream/src/lib.rs
sleep 0.1
cat > components/text-engine-stream/Cargo.toml <<'EOF'
[package]
name = "text-engine-stream"
version = "0.1.0"
edition = "2021"
[workspace]
[lib]
crate-type = ["cdylib"]
[dependencies]
wit-bindgen = "0.63"
EOF
cat > components/text-engine-stream/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine-stream",
    world: "text-engine-stream",
});

use exports::docs::text_engine_stream::processor::{Guest, GuestChunkReader, ChunkReader};
use std::cell::Cell;

struct MyChunkReader {
    total_size: u32,
    offset: Cell<u32>,
    chunk_size: u32,
}

impl GuestChunkReader for MyChunkReader {
    fn read_chunk(&self) -> Option<Vec<u8>> {
        let offset = self.offset.get();
        if offset >= self.total_size {
            return None;
        }
        let remaining = self.total_size - offset;
        let size = std::cmp::min(self.chunk_size, remaining);
        let mut chunk = vec![0u8; size as usize];
        for i in 0..size {
            chunk[i as usize] = ((offset + i) % 256) as u8;
        }
        self.offset.set(offset + size);
        Some(chunk)
    }
}

struct StreamEngine;

impl Guest for StreamEngine {
    type ChunkReader = MyChunkReader;

    fn process_list(data: Vec<u8>) -> u32 {
        data.iter().map(|&b| b as u32).sum()
    }

    fn open_reader(total_size: u32) -> ChunkReader {
        ChunkReader::new(MyChunkReader {
            total_size,
            offset: Cell::new(0),
            chunk_size: 1024 * 1024,
        })
    }
}

export!(StreamEngine);
EOF

echo "=== [4/7] Host runtime_v14 ==="
rm -f host/src/runtime_v14.rs
sleep 0.1
cat > host/src/runtime_v14.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use wasmtime::component::{Component, Linker, ResourceAny};
use wasmtime::{Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine-stream",
    world: "text-engine-stream",
});

pub struct MyState {
    ctx: WasiCtx,
    table: wasmtime::component::ResourceTable,
    limits: StoreLimits,
}

impl WasiView for MyState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.ctx, table: &mut self.table }
    }
}

pub struct OpenReader {
    pub store: Store<MyState>,
    pub bindings: TextEngineStream,
    pub reader: ResourceAny,
}

pub struct Runtime {
    engine: Engine,
    component: Component,
    linker: Linker<MyState>,
    stateful_reader: Mutex<Option<OpenReader>>,
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
        Ok(Arc::new(Self {
            engine,
            component,
            linker,
            stateful_reader: Mutex::new(None),
        }))
    }

    fn new_store(&self) -> Store<MyState> {
        let wasi = WasiCtxBuilder::new().build();
        let limits = StoreLimitsBuilder::new().memory_size(512 * 1024 * 1024).build(); // 512 MB limit
        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
            limits,
        });
        store.limiter(|state| &mut state.limits);
        store
    }

    pub fn process_list(&self, size_mb: u32) -> Result<(u32, f64)> {
        let mut store = self.new_store();
        let b = TextEngineStream::instantiate(&mut store, &self.component, &self.linker)?;
        
        let data = vec![0u8; (size_mb * 1024 * 1024) as usize];
        
        let start = Instant::now();
        let res = b.docs_text_engine_stream_processor().call_process_list(&mut store, &data)?;
        let duration = start.elapsed().as_secs_f64() * 1000.0;
        
        Ok((res, duration))
    }

    pub fn open_reader(&self, size_mb: u32) -> Result<()> {
        let mut store = self.new_store();
        let b = TextEngineStream::instantiate(&mut store, &self.component, &self.linker)?;
        
        let res = b.docs_text_engine_stream_processor().call_open_reader(&mut store, size_mb * 1024 * 1024)?;
        
        *self.stateful_reader.lock().unwrap() = Some(OpenReader { store, bindings: b, reader: res });
        Ok(())
    }

    pub fn read_all_chunks(&self) -> Result<(u32, f64)> {
        let mut guard = self.stateful_reader.lock().unwrap();
        if let Some(ref mut state) = *guard {
            let processor = state.bindings.docs_text_engine_stream_processor();
            let reader_dispatcher = processor.chunk_reader();
            
            let start = Instant::now();
            let mut total_sum: u32 = 0;
            
            loop {
                let chunk_opt = reader_dispatcher.call_read_chunk(&mut state.store, state.reader)?;
                match chunk_opt {
                    Some(chunk) => {
                        total_sum = total_sum.wrapping_add(chunk.iter().map(|&b| b as u32).sum::<u32>());
                    }
                    None => break,
                }
            }
            
            let duration = start.elapsed().as_secs_f64() * 1000.0;
            Ok((total_sum, duration))
        } else {
            anyhow::bail!("No open reader");
        }
    }
}
EOF

if ! grep -q 'pub mod runtime_v14;' host/src/lib.rs; then
  echo 'pub mod runtime_v14;' >> host/src/lib.rs
fi
touch host/src/lib.rs

echo "=== [5/7] Integration tests ==="
rm -f host/tests/integration_v14.rs
sleep 0.1
cat > host/tests/integration_v14.rs <<'EOF'
use std::path::PathBuf;

fn wasm_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap()
        .join("components/text-engine-stream/target/wasm32-wasip1/release/text_engine_stream.wasm")
}

#[test]
fn test_v14_stream_memory_path() {
    let path = wasm_path();
    if !path.exists() { eprintln!("Skipping"); return; }
    let rt = host::runtime_v14::Runtime::new(&path).expect("load");

    // 1. Передача через list<u8> (10 MB)
    let (sum_list, time_list) = rt.process_list(10).expect("process_list");
    println!("List: sum={}, time={:.2} ms", sum_list, time_list);
    assert!(time_list > 0.0);

    // 2. Потоковая передача (10 MB)
    rt.open_reader(10).expect("open_reader");
    let (sum_stream, time_stream) = rt.read_all_chunks().expect("read_all");
    println!("Stream: sum={}, time={:.2} ms", sum_stream, time_stream);
    assert!(time_stream > 0.0);
}
EOF

echo "=== [6/7] Visual demo (demo-web-ui-ch14) ==="
if [ ! -d "demo-web-ui-ch14" ]; then
  cargo new demo-web-ui-ch14 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch14/Cargo.toml demo-web-ui-ch14/src/main.rs
mkdir -p demo-web-ui-ch14/static
rm -f demo-web-ui-ch14/static/index.html
sleep 0.1
cat > demo-web-ui-ch14/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch14"
version.workspace = true
edition.workspace = true
[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF
cat > demo-web-ui-ch14/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v14::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn list_route(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.process_list(100)).await {
        Ok(Ok((sum, time))) => Json(json!({ "sum": sum, "time_ms": time, "size_mb": 100 })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn open_reader_route(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.open_reader(100)).await {
        Ok(Ok(_)) => Json(json!({ "status": "opened" })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn stream_route(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.read_all_chunks()).await {
        Ok(Ok((sum, time))) => Json(json!({ "sum": sum, "time_ms": time, "size_mb": 100 })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-stream/target/wasm32-wasip1/release/text_engine_stream.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/list", post(list_route))
        .route("/open", post(open_reader_route))
        .route("/stream", post(stream_route))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3013").await?;
    println!("🚀 Demo UI (Ch14): http://127.0.0.1:3013");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > demo-web-ui-ch14/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch14: Streams</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0; --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444; --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg);color:var(--tx);min-height:100vh; display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:800px;width:100%;background:var(--panel); border:1px solid var(--br);border-radius:12px;padding:2rem; box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem; background:linear-gradient(135deg,var(--ac),#a78bfa); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
  .panel { background: var(--bg); border: 1px solid var(--br); border-radius: 8px; padding: 1.25rem; text-align: center; }
  h2 { font-size: .9rem; font-weight: 600; margin-bottom: .5rem; color: var(--ac); }
  .desc { font-size: .75rem; color: var(--mu); margin-bottom: 1rem; }
  button { padding: .6rem 1rem; border-radius: 6px; border: none; font-weight: 600; cursor: pointer; width: 100%; margin-bottom: 0.5rem; }
  button.primary { background: var(--ac); color: #0c1222; }
  button.warn { background: #f59e0b; color: #0c1222; }
  button.bad { background: var(--er); color: white; }
  button:hover { filter: brightness(1.1); }
  button:disabled { opacity: .5; cursor: wait; }
  .result { margin-top: 1rem; font-family: var(--mo); font-size: .85rem; background: #000; padding: 1rem; border-radius: 8px; min-height: 50px; white-space: pre-wrap; text-align: left; }
  .res-ok { color: var(--ok); }
  .res-err { color: var(--er); }
</style>
</head>
<body>
<div class="box">
  <h1>Streams & Memory Path</h1>
  <p class="sub">Compare full copy (list) vs streaming (resource)</p>

  <div class="grid">
    <div class="panel">
      <h2>List (Full Copy)</h2>
      <p class="desc">Send 100 MB at once.<br>High memory usage.</p>
      <button class="primary" onclick="run('/list', 'out-list')">Send 100 MB List</button>
      <div class="result" id="out-list"></div>
    </div>
    <div class="panel">
      <h2>Stream (Resource)</h2>
      <p class="desc">Read 100 MB in 1 MB chunks.<br>Low memory usage.</p>
      <button class="warn" onclick="openThenStream()">Open & Stream 100 MB</button>
      <div class="result" id="out-stream"></div>
    </div>
  </div>
</div>
<script>
async function run(url, outId) {
  const out = document.getElementById(outId);
  out.innerHTML = 'Processing...'; out.className = 'result';
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  try {
    const res = await fetch(url, { method: 'POST' });
    const data = await res.json();
    if (data.error) {
      out.innerHTML = `<span class="res-err">${data.error}</span>`;
    } else {
      out.innerHTML = `<span class="res-ok">Sum: ${data.sum}\nTime: ${data.time_ms.toFixed(2)} ms\nSize: ${data.size_mb} MB</span>`;
    }
  } catch(e) {
    out.innerHTML = `<span class="res-err">Network error: ${e}</span>`;
  } finally {
    document.querySelectorAll('button').forEach(b => b.disabled = false);
  }
}

async function openThenStream() {
  const out = document.getElementById('out-stream');
  out.innerHTML = 'Opening reader...'; out.className = 'result';
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  try {
    await fetch('/open', { method: 'POST' });
    out.innerHTML = 'Streaming...';
    const res = await fetch('/stream', { method: 'POST' });
    const data = await res.json();
    if (data.error) {
      out.innerHTML = `<span class="res-err">${data.error}</span>`;
    } else {
      out.innerHTML = `<span class="res-ok">Sum: ${data.sum}\nTime: ${data.time_ms.toFixed(2)} ms\nSize: ${data.size_mb} MB</span>`;
    }
  } catch(e) {
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
(cd components/text-engine-stream && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch14 --quiet

echo "✅ Готово. Следующие шаги:"
echo "  1. Тесты:  (cd host && cargo test --test integration_v14)"
echo "  2. Демо:   cargo run -p demo-web-ui-ch14 --release"
echo "  3. Открыть: http://127.0.0.1:3013"