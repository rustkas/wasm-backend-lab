#!/usr/bin/env bash
# scripts/setup-ch21.sh
#
# Глава 21: Working managed runtime — финальная сборка.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT=3021
DEMO_DIR="demo-web-ui-ch21"

echo "=== [0/8] Cleanup & Pre-flight checks ==="
rm -rf "components/managed-runtime-v1"
rm -rf "components/managed-runtime-v2"
rm -rf "$DEMO_DIR"
rm -f "host/src/runtime_v21.rs"
rm -f "host/tests/integration_ch21.rs"
sed -i '/pub mod runtime_v21;/d' host/src/lib.rs 2>/dev/null || true

if ! command -v cargo-component >/dev/null 2>&1; then
    echo "❌ cargo-component не установлен. Установите: cargo install cargo-component --locked"
    exit 1
fi
rustup target add wasm32-wasip1 wasm32-wasip2 >/dev/null 2>&1 || true

REQUIRED=(runtime_v7 runtime_v9 runtime_v13 runtime_v15 runtime_v16 runtime_v17 runtime_v18)
for mod in "${REQUIRED[@]}"; do
    if [ ! -f "host/src/${mod}.rs" ]; then
        echo "❌ host/src/${mod}.rs не найден. Убедитесь, что главы 7-18 завершены."
        exit 1
    fi
done
echo "✅ Базовые модули host на месте."

echo "=== [1/8] Workspace Cargo.toml (members + exclude) ==="
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()

comps = ["managed-runtime-v1", "managed-runtime-v2"]
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if m:
    inner = m.group(1).rstrip()
    if not inner.endswith(','): inner += ','
    for c in comps:
        if f'"components/{c}"' not in inner:
            inner += f'\n    "components/{c}",'
    s = s[:m.start()] + 'exclude = [' + inner + '\n]' + s[m.end():]

m = re.search(r'members\s*=\s*\[(.*?)\]', s, re.S)
if m:
    inner = m.group(1).rstrip()
    if not inner.endswith(','): inner += ','
    target = '"demo-web-ui-ch21"'
    if target not in inner:
        inner += f'\n    {target},'
        s = s[:m.start()] + 'members = [' + inner + '\n]' + s[m.end():]
    else:
        print("demo-web-ui-ch21 already in members.")

p.write_text(s)
print("✅ Workspace Cargo.toml updated.")
PY

echo "=== [2/8] WIT Contracts for Managed Runtime ==="
mkdir -p wit/managed-runtime
cat > wit/managed-runtime/world.wit <<'EOF'
package docs:managed-runtime@0.1.0;

interface processor {
    process: func(input: string) -> result<string, string>;
    get-version: func() -> string;
}

world managed-runtime {
    export processor;
}
EOF

echo "=== [3/8] Guest Components for Ch21 ==="
create_guest() {
    local ver="$1"
    local dir="components/managed-runtime-v${ver}"
    local pkg="managed-runtime-v${ver}"
    
    cargo new "$dir" --lib --vcs none >/dev/null 2>&1 || true
    
    cat > "$dir/Cargo.toml" <<EOF
[package]
name = "${pkg}"
version = "0.1.0"
edition = "2021"

[workspace]

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = "0.63"

[package.metadata.component.target]
world = "managed-runtime"
EOF

    mkdir -p "$dir/wit"
    cp -r wit/managed-runtime/* "$dir/wit/"

    cat > "$dir/src/lib.rs" <<EOF
//! Managed Runtime V${ver} — версия ${ver}
wit_bindgen::generate!({
    path: "wit",
    world: "managed-runtime",
});

struct Processor;
impl exports::docs::managed_runtime::processor::Guest for Processor {
    fn process(input: String) -> Result<String, String> {
        Ok(format!("[V${ver}] {}", input.to_uppercase()))
    }
    fn get_version() -> String {
        "${ver}".to_string()
    }
}
export!(Processor);
EOF
}

create_guest "1"
create_guest "2"

echo "=== [4/8] Build Guest Components ==="
for v in 1 2; do
    echo "→ Building managed-runtime-v${v}..."
    (cd "components/managed-runtime-v${v}" && cargo component build --release --target wasm32-wasip2 --quiet)
done

echo "=== [5/8] Host Module: runtime_v21.rs ==="
cat > host/src/runtime_v21.rs <<'EOF'
//! host/src/runtime_v21.rs
use anyhow::Result;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use wasmtime::component::{Component, Linker};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/managed-runtime",
    world: "managed-runtime",
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

#[derive(Clone)]
pub struct Manifest {
    pub name: String,
    pub version: String,
    pub required_capabilities: Vec<String>,
}

pub struct Metrics {
    pub total_requests: AtomicU64,
    pub successful_requests: AtomicU64,
    pub failed_requests: AtomicU64,
}

pub struct Runtime {
    engine: Engine,
    components: Mutex<HashMap<String, (Component, Manifest)>>,
    pub metrics: Metrics,
}

impl Runtime {
    pub fn new() -> Result<Self> {
        let engine = Engine::default();
        Ok(Self {
            engine,
            components: Mutex::new(HashMap::new()),
            metrics: Metrics {
                total_requests: AtomicU64::new(0),
                successful_requests: AtomicU64::new(0),
                failed_requests: AtomicU64::new(0),
            },
        })
    }

    pub fn register(&self, path: &Path, manifest: Manifest) -> Result<()> {
        if manifest.required_capabilities.is_empty() {
            anyhow::bail!("Admission Denied: manifest must require at least one capability");
        }

        let component = Component::from_file(&self.engine, path)?;
        let mut reg = self.components.lock().unwrap();
        reg.insert(manifest.name.clone(), (component, manifest));
        Ok(())
    }

    pub fn invoke(&self, name: &str, input: &str) -> Result<String> {
        self.metrics.total_requests.fetch_add(1, Ordering::Relaxed);
        
        let result = self.do_invoke(name, input);
        
        match &result {
            Ok(_) => { self.metrics.successful_requests.fetch_add(1, Ordering::Relaxed); }
            Err(_) => { self.metrics.failed_requests.fetch_add(1, Ordering::Relaxed); }
        }
        result
    }

    fn do_invoke(&self, name: &str, input: &str) -> Result<String> {
        let reg = self.components.lock().unwrap();
        let (component, _manifest) = reg.get(name).ok_or_else(|| anyhow::anyhow!("Component not found"))?;

        let mut linker = Linker::new(&self.engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;

        let wasi = WasiCtxBuilder::new().build();
        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });

        let bindings = ManagedRuntime::instantiate(&mut store, component, &linker)?;
        let res = bindings.docs_managed_runtime_processor().call_process(&mut store, input)?;
        
        match res {
            Ok(s) => Ok(s),
            Err(e) => anyhow::bail!(e),
        }
    }

    pub fn hot_swap(&self, name: &str, new_path: &Path) -> Result<()> {
        let new_component = Component::from_file(&self.engine, new_path)?;
        let mut reg = self.components.lock().unwrap();
        if let Some((comp, _)) = reg.get_mut(name) {
            *comp = new_component;
            Ok(())
        } else {
            anyhow::bail!("Component not found for swap")
        }
    }

    pub fn get_metrics(&self) -> String {
        let total = self.metrics.total_requests.load(Ordering::Relaxed);
        let success = self.metrics.successful_requests.load(Ordering::Relaxed);
        let failed = self.metrics.failed_requests.load(Ordering::Relaxed);
        
        format!(
            "# HELP wasm_runtime_requests_total Total requests\n# TYPE wasm_runtime_requests_total counter\nwasm_runtime_requests_total {}\n# HELP wasm_runtime_requests_success Successful requests\n# TYPE wasm_runtime_requests_success counter\nwasm_runtime_requests_success {}\n# HELP wasm_runtime_requests_failed Failed requests\n# TYPE wasm_runtime_requests_failed counter\nwasm_runtime_requests_failed {}\n",
            total, success, failed
        )
    }
}
EOF

if ! grep -qx "pub mod runtime_v21;" host/src/lib.rs; then
    echo "pub mod runtime_v21;" >> host/src/lib.rs
fi

echo "=== [6/8] Demo: demo-web-ui-ch21 ==="
mkdir -p "$DEMO_DIR/src" "$DEMO_DIR/static"

cat > "$DEMO_DIR/Cargo.toml" <<'EOF'
[package]
name = "demo-web-ui-ch21"
version.workspace = true
edition.workspace = true

[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF

cat > "$DEMO_DIR/src/main.rs" <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router, extract::State};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use host::runtime_v21::{Runtime, Manifest};

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

fn wasm_path(ver: &str) -> PathBuf {
    // Исправление E0716: создаем владеющий PathBuf, чтобы избежать drop временного значения
    let base = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf();
    let stem = format!("managed_runtime_v{}", ver);
    for target in ["wasm32-wasip2", "wasm32-wasip1"] {
        let p = base.join(format!("components/managed-runtime-v{}/target/{}/release/{}.wasm", ver, target, stem));
        if p.exists() { return p; }
    }
    panic!("WASM not found for version {}", ver);
}

async fn setup_components(rt: Arc<Runtime>) {
    let manifest1 = Manifest {
        name: "demo-text".into(),
        version: "1.0".into(),
        required_capabilities: vec!["fs:read".into()],
    };
    rt.register(&wasm_path("1"), manifest1).unwrap();
}

async fn invoke(State(rt): State<Arc<Runtime>>, Json(payload): Json<Value>) -> Json<Value> {
    let input = payload["input"].as_str().unwrap_or("hello");
    match rt.invoke("demo-text", input) {
        Ok(res) => Json(json!({ "result": res })),
        Err(e) => Json(json!({ "error": e.to_string() })),
    }
}

async fn swap(State(rt): State<Arc<Runtime>>) -> Json<Value> {
    match rt.hot_swap("demo-text", &wasm_path("2")) {
        Ok(_) => Json(json!({ "result": "Hot-swap successful to v2" })),
        Err(e) => Json(json!({ "error": e.to_string() })),
    }
}

async fn metrics(State(rt): State<Arc<Runtime>>) -> String {
    rt.get_metrics()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let rt = Arc::new(Runtime::new()?);
    setup_components(rt.clone()).await;

    let app = Router::new()
        .route("/", get(index))
        .route("/api/invoke", post(invoke))
        .route("/api/swap", post(swap))
        .route("/metrics", get(metrics))
        .with_state(rt);

    let addr = "127.0.0.1:3021";
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("🚀 Managed Runtime (Ch21): http://{}", addr);
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > "$DEMO_DIR/static/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<title>Глава 21 — Managed Runtime</title>
<style>
  body { font-family: -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; padding: 2rem; display: flex; justify-content: center; }
  .container { max-width: 800px; width: 100%; }
  h1 { text-align: center; color: #38bdf8; }
  .panel { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 1.5rem; margin-bottom: 1rem; }
  button { background: #38bdf8; color: #0c1222; border: none; padding: 0.5rem 1rem; border-radius: 4px; cursor: pointer; font-weight: bold; }
  button:hover { background: #0ea5e9; }
  pre { background: #000; padding: 1rem; border-radius: 4px; color: #22c55e; overflow-x: auto; }
  .flex { display: flex; gap: 1rem; }
  .flex > * { flex: 1; }
</style>
</head>
<body>
<div class="container">
  <h1>Managed Runtime Platform</h1>
  
  <div class="panel">
    <h3>1. Invoke Component</h3>
    <div class="flex">
      <input id="input" type="text" value="hello world" style="padding:0.5rem; background:#0f172a; border:1px solid #334155; color:#fff; border-radius:4px;">
      <button onclick="invoke()">Invoke</button>
    </div>
    <pre id="res">-</pre>
  </div>

  <div class="panel">
    <h3>2. Lifecycle: Hot-Swap</h3>
    <p>Атомарно заменить работающий компонент на версию 2.</p>
    <button onclick="swap()">Hot-Swap to v2</button>
    <pre id="swap-res">-</pre>
  </div>

  <div class="panel">
    <h3>3. Observability</h3>
    <p>Метрики доступны в формате Prometheus: <a href="/metrics" target="_blank" style="color:#38bdf8;">/metrics</a></p>
  </div>
</div>

<script>
async function invoke() {
  const res = document.getElementById('res');
  const input = document.getElementById('input').value;
  res.textContent = 'Loading...';
  try {
    const req = await fetch('/api/invoke', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ input }) });
    const data = await req.json();
    res.textContent = data.result || data.error;
  } catch(e) { res.textContent = 'Error: ' + e; }
}

async function swap() {
  const res = document.getElementById('swap-res');
  res.textContent = 'Swapping...';
  try {
    const req = await fetch('/api/swap', { method: 'POST' });
    const data = await req.json();
    res.textContent = data.result || data.error;
  } catch(e) { res.textContent = 'Error: ' + e; }
}
</script>
</body>
</html>
HTML_EOF

echo "=== [7/8] Tests ==="
mkdir -p host/tests
cat > host/tests/integration_ch21.rs <<'EOF'
#[tokio::test]
async fn test_managed_runtime_admission() {
    let rt = host::runtime_v21::Runtime::new().unwrap();
    let manifest = host::runtime_v21::Manifest {
        name: "test".into(),
        version: "1.0".into(),
        required_capabilities: vec![],
    };
    let path = std::path::Path::new("fake.wasm");
    let result = rt.register(path, manifest);
    assert!(result.is_err(), "Admission должен отклонить пустые capabilities");
}
EOF

echo "=== [8/8] Cargo check ==="
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch21 --quiet

echo "✅ Глава 21 успешно собрана!"
cat <<MSG

Запуск:
  cargo run -p demo-web-ui-ch21 --release

Открыть:
  http://127.0.0.1:${PORT}

Что проверить:
  • Invoke: вызывает компонент v1.
  • Hot-Swap: переключает на v2.
  • /metrics: отдаёт метрики Prometheus.
MSG