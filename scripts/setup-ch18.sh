#!/usr/bin/env bash
# scripts/setup-ch18.sh
#
# Автоматическая настройка Главы 18: Composition models (Host Orchestration).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/6] Exclude new components from workspace ==="
for comp in text-engine-upper text-engine-prefix; do
  if ! grep -q "components/$comp" Cargo.toml; then
    python3 - <<PY
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if not m: raise SystemExit("exclude array not found")
inner = m.group(1).rstrip()
if not inner.endswith(','): inner += ','
inner += '\n    "components/$comp",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added $comp to exclude.")
PY
  fi
done

echo "=== [2/6] Guest components ==="
# 1. Upper Component
if [ ! -d "components/text-engine-upper" ]; then
  cargo new components/text-engine-upper --lib --vcs none >/dev/null
fi
rm -f components/text-engine-upper/Cargo.toml components/text-engine-upper/src/lib.rs
sleep 0.1
cat > components/text-engine-upper/Cargo.toml <<'EOF'
[package]
name = "text-engine-upper"
version = "0.1.0"
edition = "2021"
[workspace]
[lib]
crate-type = ["cdylib"]
[dependencies]
wit-bindgen = "0.63"
EOF
cat > components/text-engine-upper/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});
struct UpperEngine;
impl exports::docs::text_engine::processor::Guest for UpperEngine {
    fn process(input: String) -> String {
        input.to_uppercase()
    }
}
export!(UpperEngine);
EOF

# 2. Prefix Component (ИСПРАВЛЕНО: используем нижний регистр для префикса)
if [ ! -d "components/text-engine-prefix" ]; then
  cargo new components/text-engine-prefix --lib --vcs none >/dev/null
fi
rm -f components/text-engine-prefix/Cargo.toml components/text-engine-prefix/src/lib.rs
sleep 0.1
cat > components/text-engine-prefix/Cargo.toml <<'EOF'
[package]
name = "text-engine-prefix"
version = "0.1.0"
edition = "2021"
[workspace]
[lib]
crate-type = ["cdylib"]
[dependencies]
wit-bindgen = "0.63"
EOF
cat > components/text-engine-prefix/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});
struct PrefixEngine;
impl exports::docs::text_engine::processor::Guest for PrefixEngine {
    fn process(input: String) -> String {
        format!("pre_{}", input) // Изменено на нижний регистр!
    }
}
export!(PrefixEngine);
EOF

echo "=== [3/6] Host runtime_v18 (Pipeline) ==="
rm -f host/src/runtime_v18.rs
sleep 0.1
cat > host/src/runtime_v18.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use wasmtime::component::{Component, Linker};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine",
    world: "text-engine",
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
    linker: Linker<MyState>,
    pub component_upper: Component,
    pub component_prefix: Component,
}

impl Runtime {
    pub fn new(upper_path: &Path, prefix_path: &Path) -> Result<Arc<Self>> {
        if !upper_path.exists() || !prefix_path.exists() {
            anyhow::bail!("One of the WASM components is missing.");
        }
        let engine = Engine::default();
        let mut linker = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
        
        let component_upper = Component::from_file(&engine, upper_path)?;
        let component_prefix = Component::from_file(&engine, prefix_path)?;
        
        Ok(Arc::new(Self {
            engine,
            linker,
            component_upper,
            component_prefix,
        }))
    }

    fn run_single(&self, component: &Component, input: &str) -> Result<String> {
        let wasi = WasiCtxBuilder::new().build();
        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });
        let bindings = TextEngine::instantiate(&mut store, component, &self.linker)?;
        let res = bindings.docs_text_engine_processor().call_process(&mut store, input)?;
        Ok(res)
    }

    pub fn process_pipeline(&self, first: &str, second: &str, input: &str) -> Result<String> {
        let comp1 = if first == "upper" { &self.component_upper } else { &self.component_prefix };
        let comp2 = if second == "upper" { &self.component_upper } else { &self.component_prefix };

        let intermediate = self.run_single(comp1, input)?;
        let final_res = self.run_single(comp2, &intermediate)?;
        
        Ok(final_res)
    }
}
EOF

if ! grep -q 'pub mod runtime_v18;' host/src/lib.rs; then
  echo 'pub mod runtime_v18;' >> host/src/lib.rs
fi
touch host/src/lib.rs

echo "=== [4/6] Integration tests ==="
rm -f host/tests/integration_v18.rs
sleep 0.1
cat > host/tests/integration_v18.rs <<'EOF'
use std::path::PathBuf;

fn upper_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap()
        .join("components/text-engine-upper/target/wasm32-wasip1/release/text_engine_upper.wasm")
}
fn prefix_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap()
        .join("components/text-engine-prefix/target/wasm32-wasip1/release/text_engine_prefix.wasm")
}

#[test]
fn test_v18_host_orchestration() {
    let rt = host::runtime_v18::Runtime::new(&upper_path(), &prefix_path()).expect("load");

    // 1. Upper -> Prefix ("hello" -> "HELLO" -> "pre_HELLO")
    let res1 = rt.process_pipeline("upper", "prefix", "hello").unwrap();
    assert_eq!(res1, "pre_HELLO");

    // 2. Prefix -> Upper ("hello" -> "pre_hello" -> "PRE_HELLO")
    let res2 = rt.process_pipeline("prefix", "upper", "hello").unwrap();
    assert_eq!(res2, "PRE_HELLO"); 
}
EOF

echo "=== [5/6] Visual demo (demo-web-ui-ch18) ==="
if [ ! -d "demo-web-ui-ch18" ]; then
  cargo new demo-web-ui-ch18 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch18/Cargo.toml demo-web-ui-ch18/src/main.rs
mkdir -p demo-web-ui-ch18/static
rm -f demo-web-ui-ch18/static/index.html
sleep 0.1
cat > demo-web-ui-ch18/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch18"
version.workspace = true
edition.workspace = true
[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF
cat > demo-web-ui-ch18/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v18::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Json(p): Json<Value>) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    let step1 = p["step1"].as_str().unwrap_or("upper").to_string();
    let step2 = p["step2"].as_str().unwrap_or("prefix").to_string();
    
    match tokio::task::spawn_blocking(move || rt.process_pipeline(&step1, &step2, &input)).await {
        Ok(Ok(output)) => Json(json!({ "output": output })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let upper = manifest.parent().unwrap().join("components/text-engine-upper/target/wasm32-wasip1/release/text_engine_upper.wasm");
    let prefix = manifest.parent().unwrap().join("components/text-engine-prefix/target/wasm32-wasip1/release/text_engine_prefix.wasm");
    
    if !upper.exists() || !prefix.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&upper, &prefix)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/process", post(process))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3017").await?;
    println!("🚀 Demo UI (Ch18): http://127.0.0.1:3017");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > demo-web-ui-ch18/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch18: Composition</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0; --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444; --wr:#f59e0b; --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg);color:var(--tx);min-height:100vh; display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:900px;width:100%;background:var(--panel); border:1px solid var(--br);border-radius:12px;padding:2rem; box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem; background:linear-gradient(135deg,var(--ac),#a78bfa); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  
  .pipeline { display: flex; align-items: center; justify-content: space-between; margin-bottom: 2rem; background: var(--bg); padding: 1.5rem; border-radius: 8px; border: 1px solid var(--br); }
  .step-box { text-align: center; flex: 1; }
  select { padding: .6rem; border-radius: 6px; background: var(--panel); border: 1px solid var(--br); color: var(--tx); font-family: var(--mo); font-size: 1rem; width: 150px; }
  .arrow { font-size: 2rem; color: var(--mu); margin: 0 1rem; }
  
  .input-row { display: flex; gap: 1rem; margin-bottom: 1.5rem; }
  input[type=text] { flex-grow: 1; padding: .8rem; background: var(--bg); border: 1px solid var(--br); color: var(--tx); border-radius: 8px; font-family: var(--mo); }
  button { padding: .8rem 1.5rem; background: var(--ac); color: #0c1222; border: none; border-radius: 8px; font-weight: 600; cursor: pointer; }
  button:hover { filter: brightness(1.1); }
  button:disabled { opacity: .5; cursor: wait; }
  
  .result { background: #000; border-radius: 8px; padding: 1.5rem; font-family: var(--mo); font-size: 1rem; color: var(--ok); min-height: 60px; }
</style>
</head>
<body>
<div class="box">
  <h1>Host Orchestration Pipeline</h1>
  <p class="sub">Chain two components together (A -> B)</p>

  <div class="pipeline">
    <div class="step-box">
      <div style="font-size:.8rem;color:var(--mu);margin-bottom:.5rem">STEP 1</div>
      <select id="step1">
        <option value="upper">UpperCase</option>
        <option value="prefix">Prefix</option>
      </select>
    </div>
    <div class="arrow">→</div>
    <div class="step-box">
      <div style="font-size:.8rem;color:var(--mu);margin-bottom:.5rem">STEP 2</div>
      <select id="step2">
        <option value="prefix">Prefix</option>
        <option value="upper">UpperCase</option>
      </select>
    </div>
  </div>

  <div class="input-row">
    <input type="text" id="input" value="hello composition">
    <button class="process" onclick="run()">Run Pipeline</button>
  </div>

  <div class="result" id="out">Result will appear here...</div>
</div>
<script>
async function run() {
  const out = document.getElementById('out');
  out.textContent = 'Processing...';
  try {
    const res = await fetch('/process', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: document.getElementById('input').value,
        step1: document.getElementById('step1').value,
        step2: document.getElementById('step2').value
      })
    });
    const data = await res.json();
    if (data.error) { out.textContent = 'Error: ' + data.error; }
    else { out.textContent = data.output; }
  } catch(e) { out.textContent = 'Network error: ' + e; }
}
</script>
</body>
</html>
HTML_EOF

echo "=== [6/6] Build & verify ==="
(cd components/text-engine-upper && cargo component build --release --quiet)
(cd components/text-engine-prefix && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch18 --quiet

echo "✅ Готово. Следующие шаги:"
echo "  1. Тесты:  (cd host && cargo test --test integration_v18)"
echo "  2. Демо:   cargo run -p demo-web-ui-ch18 --release"
echo "  3. Открыть: http://127.0.0.1:3017"