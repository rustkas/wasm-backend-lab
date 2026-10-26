#!/usr/bin/env bash
# scripts/setup-ch19.sh
#
# Автоматическая настройка Главы 19: Test architecture and independent build.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [0/7] Cleanup previous state ==="
# Удаляем всё, что могло остаться от прошлых запусков
rm -rf components/text-engine-independent
rm -rf components/text-engine-independent.bak
rm -rf target/ch19-backup
rm -rf artifacts/text-engine-independent
rm -f host/tests/contract_v19.rs
# Убираем возможные упоминания из Cargo.toml
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()
# Удаляем из exclude
s = re.sub(r',\s*"components/text-engine-independent"', '', s)
s = re.sub(r',\s*"components/text-engine-independent\.bak"', '', s)
# Убираем из members, если попал случайно
s = re.sub(r',\s*"components/text-engine-independent\.bak"', '', s)
p.write_text(s)
print("Cleaned Cargo.toml from previous entries.")
PY
echo "✅ Cleanup complete."

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q '"components/text-engine-independent"' Cargo.toml; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Cargo.toml")
s = p.read_text()
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if not m: raise SystemExit("exclude array not found")
inner = m.group(1).rstrip()
if not inner.endswith(','): inner += ','
inner += '\n    "components/text-engine-independent",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-independent to exclude.")
PY
fi

echo "=== [2/7] Guest component ==="
cargo new components/text-engine-independent --lib --vcs none >/dev/null
rm -f components/text-engine-independent/Cargo.toml components/text-engine-independent/src/lib.rs
sleep 0.1
cat > components/text-engine-independent/Cargo.toml <<'EOF'
[package]
name = "text-engine-independent"
version = "0.1.0"
edition = "2021"
[workspace]
[lib]
crate-type = ["cdylib"]
[dependencies]
wit-bindgen = "0.63"
EOF
cat > components/text-engine-independent/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});

struct IndependentEngine;
impl exports::docs::text_engine::processor::Guest for IndependentEngine {
    fn process(input: String) -> String {
        format!("{} [verified]", input.to_uppercase())
    }
}
export!(IndependentEngine);
EOF

echo "=== [3/7] Build & Package Artifact ==="
(cd components/text-engine-independent && cargo component build --release --quiet)

mkdir -p artifacts/text-engine-independent
cp components/text-engine-independent/target/wasm32-wasip1/release/text_engine_independent.wasm artifacts/text-engine-independent/component.wasm

cat > artifacts/text-engine-independent/manifest.toml <<'EOF'
name = "text-engine-independent"
version = "1.0.0"
hash = "sha256:dummyhash123"
required_capabilities = ["fs:read"]
EOF

echo "✅ Artifact packaged into artifacts/text-engine-independent/"

echo "=== [4/7] Host Contract Test (No Source) ==="
cat > host/tests/contract_v19.rs <<'EOF'
use std::path::PathBuf;
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

#[test]
fn test_contract_without_source() {
    let artifact_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()
        .join("artifacts/text-engine-independent/component.wasm");

    if !artifact_path.exists() {
        panic!("Artifact not found at {:?}. Run setup-ch19.sh first.", artifact_path);
    }

    let engine = Engine::default();
    let mut linker = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).unwrap();
    
    let component = Component::from_file(&engine, &artifact_path).expect("Failed to load component");
    
    let wasi = WasiCtxBuilder::new().build();
    let mut store = Store::new(&engine, MyState {
        ctx: wasi,
        table: wasmtime::component::ResourceTable::new(),
    });

    let bindings = TextEngine::instantiate(&mut store, &component, &linker).expect("Instantiate");
    let res = bindings.docs_text_engine_processor().call_process(&mut store, "hello").expect("Call");
    
    assert_eq!(res, "HELLO [verified]");
}
EOF

echo "=== [5/7] Visual demo (demo-web-ui-ch19) ==="
if [ ! -d "demo-web-ui-ch19" ]; then
  cargo new demo-web-ui-ch19 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch19/Cargo.toml demo-web-ui-ch19/src/main.rs
mkdir -p demo-web-ui-ch19/static
rm -f demo-web-ui-ch19/static/index.html
sleep 0.1
cat > demo-web-ui-ch19/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch19"
version.workspace = true
edition.workspace = true
[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF

cat > demo-web-ui-ch19/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn run_test() -> Json<Value> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let src = root.join("components/text-engine-independent");
    let backup = root.join("target/ch19-backup/text-engine-independent");

    // Перемещаем исходники в target/ (вне воркспейса)
    std::fs::create_dir_all(backup.parent().unwrap()).ok();
    let moved = std::fs::rename(&src, &backup).is_ok();

    let root_clone = root.clone();
    let output = tokio::task::spawn_blocking(move || {
        Command::new("cargo")
            .args(["test", "--test", "contract_v19", "--", "--nocapture"])
            .current_dir(root_clone.join("host"))
            .output()
    }).await.expect("join");

    // Всегда возвращаем исходники на место
    if moved {
        let _ = std::fs::rename(&backup, &src);
    }

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let success = out.status.success();
            Json(json!({ "success": success, "log": stdout }))
        }
        Err(e) => Json(json!({ "success": false, "log": format!("Failed to run cargo: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let app = Router::new()
        .route("/", get(index))
        .route("/run-test", post(run_test));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3018").await?;
    println!("🚀 Demo UI (Ch19): http://127.0.0.1:3018");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > demo-web-ui-ch19/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch19: Independent Build</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0; --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444; --wr:#f59e0b; --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg);color:var(--tx);min-height:100vh; display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:850px;width:100%;background:var(--panel); border:1px solid var(--br);border-radius:12px;padding:2rem; box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem; background:linear-gradient(135deg,var(--ac),#a78bfa); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  .tree { background: #000; padding: 1.5rem; border-radius: 8px; font-family: var(--mo); font-size: .9rem; margin-bottom: 1.5rem; color: var(--tx); line-height: 1.6; }
  .deleted { color: var(--er); text-decoration: line-through; }
  .present { color: var(--ok); }
  button { width: 100%; padding: .8rem; border-radius: 8px; border: none; font-weight: 600; cursor: pointer; background: var(--ac); color: #0c1222; font-size: 1rem; margin-bottom: 1rem;}
  button:hover { filter: brightness(1.1); }
  button:disabled { opacity: .5; cursor: wait; }
  .result { background: #000; border-radius: 8px; padding: 1rem; font-family: var(--mo); font-size: .8rem; color: var(--mu); white-space: pre-wrap; max-height: 250px; overflow-y: auto;}
</style>
</head>
<body>
<div class="box">
  <h1>Independent Build & Contract Tests</h1>
  <p class="sub">Testing the artifact without source code</p>
  <div class="tree">
    <div>📁 wasm-backend-lab/</div>
    <div>&nbsp;&nbsp;├── 📁 <span class="deleted">components/text-engine-independent/ (MOVED)</span></div>
    <div>&nbsp;&nbsp;├── 📁 artifacts/</div>
    <div>&nbsp;&nbsp;│&nbsp;&nbsp; └── 📁 text-engine-independent/</div>
    <div>&nbsp;&nbsp;│&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; ├── 📄 <span class="present">component.wasm</span></div>
    <div>&nbsp;&nbsp;│&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; └── 📄 <span class="present">manifest.toml</span></div>
    <div>&nbsp;&nbsp;└── 📁 host/</div>
    <div>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; └── 📁 tests/</div>
    <div>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; └── 📄 <span class="present">contract_v19.rs</span></div>
  </div>
  <button id="btn" onclick="runTest()">Run Contract Test (No Source)</button>
  <div class="result" id="log">Awaiting run...</div>
</div>
<script>
async function runTest() {
  const btn = document.getElementById('btn');
  const log = document.getElementById('log');
  btn.disabled = true;
  log.textContent = 'Moving source to backup, running cargo test...';
  try {
    const res = await fetch('/run-test', { method: 'POST' });
    const data = await res.json();
    log.textContent = data.log;
    if (data.success) {
      log.innerHTML = `<span style="color:var(--ok)">✅ Test Passed! (source was moved away)</span>\n\n` + log.textContent;
    } else {
      log.innerHTML = `<span style="color:var(--er)">❌ Test Failed!</span>\n\n` + log.textContent;
    }
  } catch(e) {
    log.textContent = 'Network error: ' + e;
  } finally {
    btn.disabled = false;
  }
}
</script>
</body>
</html>
HTML_EOF

echo "=== [6/7] Move source to backup ==="
BACKUP_DIR="$ROOT/target/ch19-backup"
mkdir -p "$BACKUP_DIR"
mv components/text-engine-independent "$BACKUP_DIR/text-engine-independent"
echo "Source code moved to $BACKUP_DIR"

restore() {
  if [ -d "$BACKUP_DIR/text-engine-independent" ] && [ ! -d "components/text-engine-independent" ]; then
    mv "$BACKUP_DIR/text-engine-independent" "components/text-engine-independent"
    echo "✅ Source code restored."
  fi
}
trap restore EXIT INT TERM

echo "=== [7/7] Run Contract Test (without source) ==="
(cd host && cargo test --test contract_v19)

echo "✅ Готово. Следующие шаги:"
echo "  1. Демо:   cargo run -p demo-web-ui-ch19 --release"
echo "  2. Открыть: http://127.0.0.1:3018"