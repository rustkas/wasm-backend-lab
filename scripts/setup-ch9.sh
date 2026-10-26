#!/usr/bin/env bash
# scripts/setup-ch9.sh
#
# Автоматическая настройка Главы 9: Host API design: Capabilities.
#
# Создаёт:
#   1. WIT-контракт для компонента text-engine-secure (читает файлы).
#   2. Компонент components/text-engine-secure.
#   3. host/src/runtime_v9.rs (Runtime с preopened_dir для изоляции).
#   4. host/tests/integration_v9.rs (тесты доступа к разрешенным и запрещенным файлам).
#   5. demo-web-ui-ch9/ (визуальный демо-проект).
#
# Не модифицирует существующие компоненты и код из Глав 1–8.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== [1/7] Exclude new component from workspace ==="
if ! grep -q 'components/text-engine-secure' Cargo.toml; then
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
inner += '\n    "components/text-engine-secure",\n'
p.write_text(s[:m.start()] + 'exclude = [' + inner + ']' + s[m.end():])
print("Added text-engine-secure to exclude.")
PY
fi

echo "=== [2/7] WIT contract ==="
mkdir -p wit/text-engine-secure
rm -f wit/text-engine-secure/world.wit
sleep 0.1

cat > wit/text-engine-secure/world.wit <<'EOF'
package docs:text-engine-secure@0.1.0;

interface processor {
    // Пытается прочитать файл по указанному пути
    read-file: func(path: string) -> result<string, string>;
}

world text-engine-secure {
    export processor;
}
EOF

echo "=== [3/7] Guest component ==="
if [ ! -d "components/text-engine-secure" ]; then
  cargo new components/text-engine-secure --lib --vcs none >/dev/null
fi
rm -f components/text-engine-secure/Cargo.toml components/text-engine-secure/src/lib.rs
sleep 0.1

cat > components/text-engine-secure/Cargo.toml <<'EOF'
[package]
name = "text-engine-secure"
version = "0.1.0"
edition = "2021"

[workspace]

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = "0.63"
EOF

cat > components/text-engine-secure/src/lib.rs <<'EOF'
wit_bindgen::generate!({
    path: "../../wit/text-engine-secure",
    world: "text-engine-secure",
});

use exports::docs::text_engine_secure::processor::Guest;

struct SecureEngine;

impl Guest for SecureEngine {
    fn read_file(path: String) -> Result<String, String> {
        // WASI заблокирует этот вызов, если файл не находится в разрешенной директории.
        match std::fs::read_to_string(&path) {
            Ok(content) => Ok(content),
            Err(e) => Err(format!("Failed to read: {}", e)),
        }
    }
}

export!(SecureEngine);
EOF

echo "=== [4/7] Host runtime_v9 ==="
rm -f host/src/runtime_v9.rs
sleep 0.1

cat > host/src/runtime_v9.rs <<'EOF'
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use wasmtime::component::{Component, Linker};
use wasmtime::{Engine, Store};
use wasmtime_wasi::filesystem::FsPerms;
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../wit/text-engine-secure",
    world: "text-engine-secure",
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
        
        if !Path::new("./sandbox").exists() {
            std::fs::create_dir_all("./sandbox")?;
        }

        let component = Component::from_file(&engine, wasm_path)?;
        Ok(Arc::new(Self { engine, component, linker }))
    }

    pub fn read_file(&self, path: &str) -> Result<Result<String, String>> {
        // Передаём ОДИН FsPerms, без массива и без all()
        let wasi = WasiCtxBuilder::new()
            .preopened_dir("./sandbox", "/sandbox", FsPerms::ReadWrite)?
            .build();

        let mut store = Store::new(&self.engine, MyState {
            ctx: wasi,
            table: wasmtime::component::ResourceTable::new(),
        });

        let b = TextEngineSecure::instantiate(&mut store, &self.component, &self.linker)?;
        let res = b.docs_text_engine_secure_processor().call_read_file(&mut store, path)?;
        
        Ok(res.map_err(|e| e.to_string()))
    }
}
EOF

if ! grep -q 'pub mod runtime_v9;' host/src/lib.rs; then
  echo 'pub mod runtime_v9;' >> host/src/lib.rs
fi
touch host/src/lib.rs

echo "=== [5/7] Integration tests ==="
rm -f host/tests/integration_v9.rs
sleep 0.1

# Создаем файлы для теста
mkdir -p sandbox
echo "This is an allowed file." > sandbox/allowed.txt
echo "This is a SECRET file outside the sandbox!" > secret.txt

cat > host/tests/integration_v9.rs <<'EOF'
use std::path::PathBuf;

fn wasm_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()
        .join("components/text-engine-secure/target/wasm32-wasip1/release/text_engine_secure.wasm")
}

#[test]
fn test_v9_capabilities() {
    let path = wasm_path();
    if !path.exists() {
        eprintln!("Skipping: {} not found.", path.display());
        return;
    }

    // Создаём папку sandbox и файл allowed.txt в текущей директории (host/)
    std::fs::create_dir_all("./sandbox").unwrap();
    std::fs::write("./sandbox/allowed.txt", "This is an allowed file.").unwrap();

    let rt = host::runtime_v9::Runtime::new(&path).expect("load");

    // 1. Чтение разрешенного файла (внутри /sandbox)
    let res = rt.read_file("/sandbox/allowed.txt").unwrap();
    assert!(res.is_ok(), "Should read allowed file. Error: {:?}", res.err());
    assert_eq!(res.unwrap().trim(), "This is an allowed file.");

    // 2. Попытка чтения секретного файла (за пределами /sandbox)
    let secret_res = rt.read_file("/secret.txt").unwrap();
    assert!(secret_res.is_err(), "Should NOT read secret file");
    let err = secret_res.unwrap_err();
    assert!(err.contains("PermissionDenied") || err.contains("not found") || err.contains("No such file"), 
            "Expected permission denied or not found, got: {}", err);
}
EOF

echo "=== [6/7] Visual demo (demo-web-ui-ch9) ==="
if [ ! -d "demo-web-ui-ch9" ]; then
  cargo new demo-web-ui-ch9 --bin --vcs none >/dev/null
fi
rm -f demo-web-ui-ch9/Cargo.toml demo-web-ui-ch9/src/main.rs
mkdir -p demo-web-ui-ch9/static
rm -f demo-web-ui-ch9/static/index.html
sleep 0.1

cat > demo-web-ui-ch9/Cargo.toml <<'EOF'
[package]
name = "demo-web-ui-ch9"
version.workspace = true
edition.workspace = true

[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF

cat > demo-web-ui-ch9/src/main.rs <<'EOF'
use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v9::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn read_allowed(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.read_file("/sandbox/allowed.txt")).await {
        Ok(Ok(Ok(content))) => Json(json!({ "output": content })),
        Ok(Ok(Err(e))) => Json(json!({ "error": e })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn read_secret(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    // Пытаемся прочитать файл, который лежит ЗА пределами ./sandbox
    // "/secret.txt" внутри WASI не существует, так как preopened_dir был только на ./sandbox
    match tokio::task::spawn_blocking(move || rt.read_file("/secret.txt")).await {
        Ok(Ok(Ok(content))) => Json(json!({ "output": content })),
        Ok(Ok(Err(e))) => {
            eprintln!("[guest-capability-error] {e}");
            Json(json!({ "error": "Permission denied (Capability boundary)" }))
        },
        _ => Json(json!({ "error": "internal_error" })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    // Важно: путь до .wasm внутри target/
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-secure/target/wasm32-wasip1/release/text_engine_secure.wasm");

    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!("Run `cd components/text-engine-secure && cargo component build --release` first.");
        std::process::exit(1);
    }

    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/allowed", post(read_allowed))
        .route("/secret", post(read_secret))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3008").await?;
    println!("🚀 Demo UI (Ch9): http://127.0.0.1:3008");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

cat > demo-web-ui-ch9/static/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Ch9: Capabilities</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --br:#334155; --tx:#e2e8f0;
          --mu:#94a3b8; --ac:#38bdf8; --ok:#22c55e; --er:#ef4444; --wr:#f59e0b;
          --mo:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       background:var(--bg);color:var(--tx);min-height:100vh;
       display:flex;align-items:center;justify-content:center;padding:2rem}
  .box{max-width:800px;width:100%;background:var(--panel);
       border:1px solid var(--br);border-radius:12px;padding:2rem;
       box-shadow:0 20px 60px rgba(0,0,0,.4)}
  h1{font-size:1.6rem;font-weight:600;text-align:center;margin-bottom:.35rem;
     background:linear-gradient(135deg,var(--ac),#a78bfa);
     -webkit-background-clip:text; background-clip:text;
     -webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:.9rem;margin-bottom:2rem}
  
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
  .panel { background: var(--bg); border: 1px solid var(--br); border-radius: 8px; padding: 1.25rem; text-align: center; display: flex; flex-direction: column; }
  h2 { font-size: .9rem; font-weight: 600; margin-bottom: .5rem; color: var(--ac); }
  .desc { font-size: .75rem; color: var(--mu); margin-bottom: 1rem; flex-grow: 1; }
  
  button { padding: .6rem 1rem; font-size: .85rem; font-weight: 500; border: none; border-radius: 6px; cursor: pointer; transition: .15s; width: 100%; }
  button.good { background: var(--ac); color: #0c1222; }
  button.bad { background: var(--er); color: white; }
  button:hover { filter: brightness(1.1); }
  button:disabled { opacity: .5; cursor: wait; }

  .result { margin-top: 1rem; font-family: var(--mo); font-size: .75rem; word-break: break-all; min-height: 40px; }
  .res-ok { color: var(--ok); }
  .res-err { color: var(--er); }
</style>
</head>
<body>
<div class="box">
  <h1>Capabilities: Sandbox & Preopened Dirs</h1>
  <p class="sub">WASM component attempts to read files via WASI</p>

  <div class="grid">
    <div class="panel">
      <h2>Allowed File</h2>
      <p class="desc">File inside <code>./sandbox/allowed.txt</code>.<br>WASI preopens this directory.</p>
      <button class="good" onclick="run('/allowed', 'out-allowed')">Read Allowed</button>
      <div class="result" id="out-allowed"></div>
    </div>

    <div class="panel">
      <h2>Forbidden File (Danger)</h2>
      <p class="desc">File outside sandbox: <code>/secret.txt</code>.<br>WASI blocks access.</p>
      <button class="bad" onclick="run('/secret', 'out-secret')">Read Secret</button>
      <div class="result" id="out-secret"></div>
    </div>
  </div>
</div>

<script>
async function run(url, outId) {
  const out = document.getElementById(outId);
  out.innerHTML = 'Reading...'; out.className = 'result';
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  try {
    const res = await fetch(url, { method: 'POST' });
    const data = await res.json();
    if (data.error) {
      out.innerHTML = `<span class="res-err">${data.error}</span>`;
    } else {
      out.innerHTML = `<span class="res-ok">${data.output.trim()}</span>`;
    }
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
(cd components/text-engine-secure && cargo component build --release --quiet)
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch9 --quiet

echo
echo "✅ Готово. Следующие шаги:"
echo "  1. Тесты:  (cd host && cargo test --test integration_v9)"
echo "  2. Демо:   cargo run -p demo-web-ui-ch9 --release"
echo "  3. Открыть: http://127.0.0.1:3008"