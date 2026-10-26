#!/usr/bin/env bash
# scripts/setup-ch20.sh
#
# Глава 20: Component design patterns.
# Восемь архитектурных паттернов в одном визуальном каталоге.
#
# Идемпотентен: повторный запуск не ломает уже созданное.
# Не трогает код предыдущих глав — только расширяет workspace и demo/.
#
# Уроки, зафиксированные в этом скрипте:
#   1. Не пишем `wit-bindgen = "..."` в Cargo.toml guest-компонентов.
#      Версию подбирает `cargo-component` — явное указание ломает
#      совместимость со сгенерированным кодом.
#   2. После сборки ищем .wasm в wasm32-wasip1 И wasm32-wasip2 —
#      cargo-component может выдать артефакт в любой из них.
#   3. Проверяем имена модулей host (runtime_v7.rs, не runtime_7v.rs)
#      до cargo check — иначе ошибка "unresolved import" всплывёт
#      в самом неудобном месте.
#   4. Демо-код (main.rs) содержит явные return-type у замыканий в
#      spawn_blocking и корректную конвертацию Result<(), String>
#      из runtime_v17::deploy_from_path в anyhow::Result<_>.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT=3019
DEMO_DIR="demo-web-ui-ch20"

# ============================================================
# [0/10] Pre-flight
# ============================================================
echo "=== [0/10] Pre-flight checks ==="

if ! command -v cargo-component >/dev/null 2>&1; then
    cat <<'MSG'
❌ cargo-component не установлен.
   Установите: cargo install cargo-component --locked
MSG
    exit 1
fi

CC_VERSION="$(cargo component --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
CC_RECOMMENDED="0.21.1"
if [ -n "$CC_VERSION" ] && [ "$CC_VERSION" != "$CC_RECOMMENDED" ]; then
    echo "⚠️  cargo-component v${CC_VERSION} (рекомендуется v${CC_RECOMMENDED})."
    echo "   Несовпадение версий wit-bindgen-рантайма и cargo-component"
    echo "   — частая причина ошибок линковки guest-компонентов."
    echo
fi

for tgt in wasm32-wasip1 wasm32-wasip2; do
    if ! rustup target list --installed | grep -q "$tgt"; then
        echo "→ Устанавливаю target $tgt..."
        rustup target add "$tgt"
    fi
done

# Проверяем, что host-модули, на которые ссылается демо, реально существуют
# как файлы runtime_vN.rs (а не runtime_Nv.rs — частая опечатка).
REQUIRED_MODULES=(runtime runtime_v7 runtime_v9 runtime_v13 runtime_v15 runtime_v16 runtime_v17 runtime_v18)
MISSING_HOST=()
for mod in "${REQUIRED_MODULES[@]}"; do
    if [ ! -f "host/src/$mod.rs" ]; then
        # может быть опечатка в имени — runtime_7v.rs
        num="${mod#runtime_v}"
        if [ -f "host/src/runtime_${num}v.rs" ]; then
            echo "⚠️  Найден host/src/runtime_${num}v.rs, ожидается runtime_v${num}.rs."
            echo "   Переименовываю..."
            mv "host/src/runtime_${num}v.rs" "host/src/runtime_v${num}.rs"
        else
            MISSING_HOST+=("$mod")
        fi
    fi
done

if [ ${#MISSING_HOST[@]} -gt 0 ]; then
    cat <<MSG
❌ Отсутствуют host-модули: ${MISSING_HOST[*]}
   Глава 20 требует завершённых глав 1, 7, 9, 13, 15, 16, 17, 18.
   Восстановите эти модули перед запуском.
MSG
    exit 1
fi

# Проверяем, что lib.rs их объявляет
touch host/src/lib.rs
for mod in "${REQUIRED_MODULES[@]}"; do
    if ! grep -qx "pub mod $mod;" host/src/lib.rs; then
        echo "pub mod $mod;" >> host/src/lib.rs
        echo "  + добавлено в lib.rs: pub mod $mod;"
    fi
done

echo "✅ host-модули на месте, lib.rs синхронизирован."

# ============================================================
# [1/10] WIT-контракты
# ============================================================
echo "=== [1/10] WIT contracts ==="
mkdir -p wit/text-engine-secure wit/text-engine-slow

cat > wit/text-engine-secure/world.wit <<'EOF'
package docs:text-engine-secure@0.1.0;

interface processor {
    /// Читает файл по пути. Провайдер WASI решает, разрешено ли это.
    /// Без preopen директории `fs:read` не даёт доступа — это и есть
    /// capability-граница, которую демонстрирует паттерн.
    read-file: func(path: string) -> result<string, string>;
}

world text-engine-secure {
    export processor;
}
EOF

cat > wit/text-engine-slow/world.wit <<'EOF'
package docs:text-engine-slow@0.1.0;

interface processor {
    /// Блокирует поток на `ms` миллисекунд.
    /// Нужен для drain-эксперимента: пока v1 занят, v2 можно вводить.
    process: func(ms: u32) -> string;
}

world text-engine-slow {
    export processor;
}
EOF

# ============================================================
# [2/10] Workspace exclude
# ============================================================
echo "=== [2/10] Workspace exclude ==="
python3 - <<'PY'
import re, pathlib

p = pathlib.Path("Cargo.toml")
s = p.read_text()
comps = [
    "text-engine-component", "document-engine", "text-engine-advanced",
    "text-engine-stateful", "text-engine-hang", "text-engine-secure",
    "text-engine-memory", "text-engine-crash", "text-engine-observe",
    "text-engine-resource", "text-engine-stream", "text-engine-v2",
    "text-engine-slow-v1", "text-engine-slow-v2",
    "text-engine-deployable", "text-engine-upper", "text-engine-prefix",
    "text-engine-independent",
]
m = re.search(r'exclude\s*=\s*\[(.*?)\]', s, re.S)
if not m:
    raise SystemExit("exclude array not found in workspace Cargo.toml")
inner = m.group(1).rstrip()
if not inner.endswith(','):
    inner += ','
for c in comps:
    if f'"components/{c}"' not in inner:
        inner += f'\n    "components/{c}",'
p.write_text(s[:m.start()] + 'exclude = [' + inner + '\n]' + s[m.end():])
print("Updated exclude list.")
PY

# ============================================================
# [3/10] Guest components
# ============================================================
echo "=== [3/10] Guest components ==="

create_guest() {
    local dir="$1"          # components/text-engine-secure
    local pkg="$2"          # text-engine-secure
    local world="$3"        # text-engine-secure
    local witdir="$4"       # wit/text-engine-secure
    local body="$5"         # тело impl Guest

    if [ ! -d "$dir" ]; then
        cargo component new "$pkg" --lib --path "$dir" >/dev/null
    else
        # Гарантируем, что это компонент (cdylib), а не обычный lib.
        if ! grep -q 'crate-type = \["cdylib"\]' "$dir/Cargo.toml" 2>/dev/null; then
            cargo component new "$pkg" --lib --path "$dir" --force >/dev/null
        fi
    fi

    # Копируем WIT
    rm -rf "$dir/wit"
    cp -r "$witdir" "$dir/wit"

    # Указываем мир в Cargo.toml (это обязательный metadata).
    # ВАЖНО: НЕ трогаем [dependencies] — wit-bindgen версию подбирает
    # cargo-component, явное указание ломает совместимость.
    python3 - "$dir/Cargo.toml" "$world" <<'PY'
import pathlib, sys, re
p = pathlib.Path(sys.argv[1])
world = sys.argv[2]
s = p.read_text()
s = re.sub(
    r'\[package\.metadata\.component\.target\][\s\S]*?(?=\n\[|\Z)',
    f'[package.metadata.component.target]\nworld = "{world}"\n',
    s,
)
if '[package.metadata.component.target]' not in s:
    s += f'\n[package.metadata.component.target]\nworld = "{world}"\n'
p.write_text(s)
PY

    mkdir -p "$dir/src"
    cat > "$dir/src/lib.rs" <<EOF
//! Guest-компонент главы 20: $pkg
//!
//! Никакого wit-bindgen в Cargo.toml: cargo-component добавляет его сам.
//! Явная версия — источник конфликта runtime-типов.
wit_bindgen::generate!({
    path: "wit",
    world: "$world",
});

$body
EOF
}

# 3.1 Secure
create_guest "components/text-engine-secure" "text-engine-secure" \
  "text-engine-secure" "wit/text-engine-secure" \
'struct SecureEngine;
impl exports::docs::text_engine_secure::processor::Guest for SecureEngine {
    fn read_file(path: String) -> Result<String, String> {
        std::fs::read_to_string(&path).map_err(|e| format!("Failed to read: {e}"))
    }
}
export!(SecureEngine);'

# 3.2 Slow v1 и v2 — идентичный код, разные имена (важно для drain)
SLOW_BODY='struct SlowEngine;
impl exports::docs::text_engine_slow::processor::Guest for SlowEngine {
    fn process(ms: u32) -> String {
        std::thread::sleep(std::time::Duration::from_millis(ms as u64));
        "done".to_string()
    }
}
export!(SlowEngine);'

create_guest "components/text-engine-slow-v1" "text-engine-slow-v1" \
  "text-engine-slow" "wit/text-engine-slow" "$SLOW_BODY"
create_guest "components/text-engine-slow-v2" "text-engine-slow-v2" \
  "text-engine-slow" "wit/text-engine-slow" "$SLOW_BODY"

# ============================================================
# [4/10] Build guest components
# ============================================================
echo "=== [4/10] Building components ==="

# Ищем .wasm в обоих target-каталогах — cargo-component может собрать
# под wasm32-wasip2, если WIT этого требует.
find_wasm() {
    local comp_dir="$1"
    local stem="$2"
    for target in wasm32-wasip1 wasm32-wasip2; do
        local p="$comp_dir/target/$target/release/${stem//-/_}.wasm"
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

build_comp() {
    local comp="$1"
    local dir="components/$comp"
    [ -d "$dir" ] || return 1
    echo "→ $comp"
    (cd "$dir" && cargo component build --release --quiet)
}

# Обязательные для главы 20
for c in text-engine-secure text-engine-slow-v1 text-engine-slow-v2; do
    if ! build_comp "$c"; then
        echo "❌ Сборка $c провалилась."
        exit 1
    fi
done

# Опциональные: пришли из предыдущих глав. Не падаем, если их нет.
OPTIONAL=(
    text-engine-component text-engine-v2 text-engine-stateful
    text-engine-resource text-engine-upper text-engine-prefix
    text-engine-deployable
)
MISSING_OPT=()
for c in "${OPTIONAL[@]}"; do
    if [ -d "components/$c" ]; then
        if ! build_comp "$c"; then
            echo "⚠️  $c не собрался, паттерн будет недоступен"
            MISSING_OPT+=("$c")
        fi
    else
        echo "⚠️  components/$c отсутствует, паттерн будет недоступен"
        MISSING_OPT+=("$c")
    fi
done

# ============================================================
# [5/10] Verify artefacts
# ============================================================
echo "=== [5/10] Verifying WASM artefacts ==="
for c in text-engine-secure text-engine-slow-v1 text-engine-slow-v2; do
    if p=$(find_wasm "components/$c" "$c"); then
        echo "✅ $c → $p"
    else
        echo "❌ $c: .wasm не найден ни в wasm32-wasip1, ни в wasm32-wasip2"
        ls -R "components/$c/target" 2>/dev/null | head -20
        exit 1
    fi
done

# ============================================================
# [6/10] Visual demo — Cargo.toml
# ============================================================
echo "=== [6/10] Visual demo: $DEMO_DIR ==="
mkdir -p "$DEMO_DIR/src" "$DEMO_DIR/static"

cat > "$DEMO_DIR/Cargo.toml" <<'EOF'
[package]
name = "demo-web-ui-ch20"
version.workspace = true
edition.workspace = true

[dependencies]
host = { path = "../host" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1.0"
EOF

# ============================================================
# [7/10] Visual demo — main.rs
# ============================================================
cat > "$DEMO_DIR/src/main.rs" <<'EOF'
// demo-web-ui-ch20/src/main.rs
//
// Глава 20: восемь архитектурных паттернов в одном визуальном каталоге.
//
// Уроки, зафиксированные в этом файле:
//   1. Пути к .wasm ищем в обоих target-каталогах (wasm32-wasip1 и wasm32-wasip2).
//      cargo-component может выдать артефакт в любой из них.
//   2. Замыкания в spawn_blocking имеют явно указанный тип anyhow::Result<_>.
//      Иначе tail-expression вроде `rt.deploy_from_path(...)` (возвращает
//      Result<(), String>) не сойдётся с anyhow-ошибками из ?-выражений выше.
//   3. Паттерн недоступен — это честная ошибка с подсказкой запустить setup,
//      а не паника.

use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::path::PathBuf;

use host::runtime::Runtime as ComputedRuntime;
use host::runtime_v7::Runtime as StatefulRuntime;
use host::runtime_v9::Runtime as PolicyRuntime;
use host::runtime_v13::Runtime as ResourceRuntime;
use host::runtime_v15::Runtime as ReplaceableRuntime;
use host::runtime_v16::Runtime as DrainRuntime;
use host::runtime_v17::{Runtime as DeployRuntime, Manifest};
use host::runtime_v18::Runtime as PipelineRuntime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

// ---------- Поиск WASM-артефактов ----------

fn wasm_path(comp: &str, stem: &str) -> Option<PathBuf> {
    let base = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("components")
        .join(comp)
        .join("target");

    for target in ["wasm32-wasip1", "wasm32-wasip2"] {
        let p = base
            .join(target)
            .join("release")
            .join(format!("{}.wasm", stem.replace('-', "_")));
        if p.exists() {
            return Some(p);
        }
    }
    None
}

fn must_wasm(comp: &str, stem: &str) -> anyhow::Result<PathBuf> {
    wasm_path(comp, stem).ok_or_else(|| {
        anyhow::anyhow!(
            "component `{comp}` не собран. Запустите `./scripts/setup-ch20.sh`"
        )
    })
}

// ---------- Хелпер ответа ----------

async fn finish(
    r: Result<anyhow::Result<String>, tokio::task::JoinError>,
) -> Json<Value> {
    match r {
        Ok(Ok(v)) => Json(json!({ "result": v })),
        Ok(Err(e)) => Json(json!({ "error": e.to_string() })),
        Err(e) => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

// ---------- Паттерны ----------

async fn run_computational() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-component", "text-engine-component")?;
        let rt = ComputedRuntime::new(&path)?;
        Ok(rt.process("  HELLO  ")?)
    })
    .await;
    finish(r).await
}

async fn run_plugin() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let v1 = must_wasm("text-engine-component", "text-engine-component")?;
        let v2 = must_wasm("text-engine-v2", "text-engine-v2")?;
        let rt = ReplaceableRuntime::new(&v1, &v2)?;
        rt.switch_version(2);
        Ok(rt.process("plugin demo")?)
    })
    .await;
    finish(r).await
}

async fn run_stateful() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-stateful", "text-engine-stateful")?;
        let rt = StatefulRuntime::new(&path)?;
        let _ = rt.increment_stateful()?;
        let _ = rt.increment_stateful()?;
        let v = rt.get_stateful()?;
        Ok(format!("Counter: {v}"))
    })
    .await;
    finish(r).await
}

async fn run_policy() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-secure", "text-engine-secure")?;
        std::fs::create_dir_all("./sandbox")?;
        std::fs::write("./sandbox/test.txt", b"secret data")?;
        let rt = PolicyRuntime::new(&path)?;
        match rt.read_file("/sandbox/test.txt")? {
            Ok(content) => Ok(format!("Read: {content}")),
            Err(guest_err) => Err(anyhow::anyhow!(
                "guest denied (ожидаемо без preopen): {guest_err}"
            )),
        }
    })
    .await;
    finish(r).await
}

async fn run_resource() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-resource", "text-engine-resource")?;
        let rt = ResourceRuntime::new(&path)?;
        let _ = rt.open_document("test.txt")?;
        Ok(rt.get_content()?)
    })
    .await;
    finish(r).await
}

async fn run_pipeline() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let upper = must_wasm("text-engine-upper", "text-engine-upper")?;
        let prefix = must_wasm("text-engine-prefix", "text-engine-prefix")?;
        let rt = PipelineRuntime::new(&upper, &prefix)?;
        Ok(rt.process_pipeline("upper", "prefix", "hello")?)
    })
    .await;
    finish(r).await
}

async fn run_drain() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let v1 = must_wasm("text-engine-slow-v1", "text-engine-slow-v1")?;
        let v2 = must_wasm("text-engine-slow-v2", "text-engine-slow-v2")?;
        let rt = DrainRuntime::new(&v1, &v2)?;
        rt.swap_version(2);
        let (_msg, version) = rt.process(10)?;
        Ok(format!("Processed on version {version}"))
    })
    .await;
    finish(r).await
}

async fn run_untrusted() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-deployable", "text-engine-deployable")?;
        let rt = DeployRuntime::new()?;
        let manifest = Manifest {
            name: "test".into(),
            version: "1.0".into(),
            required_capabilities: vec!["fs:read".into()],
        };
        // deploy_from_path возвращает Result<(), String> — конвертируем явно.
        match rt.deploy_from_path(&path, manifest) {
            Ok(()) => Ok("Admission ACCEPTED".to_string()),
            Err(e) => Err(anyhow::anyhow!("Admission DENIED: {e}")),
        }
    })
    .await;
    finish(r).await
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let app = Router::new()
        .route("/", get(index))
        .route("/pattern/computational", post(run_computational))
        .route("/pattern/plugin", post(run_plugin))
        .route("/pattern/stateful", post(run_stateful))
        .route("/pattern/policy", post(run_policy))
        .route("/pattern/resource", post(run_resource))
        .route("/pattern/pipeline", post(run_pipeline))
        .route("/pattern/drain", post(run_drain))
        .route("/pattern/untrusted", post(run_untrusted));

    let addr = "127.0.0.1:3019";
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("🚀 Demo UI (Ch20): http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
EOF

# ============================================================
# [8/10] Visual demo — index.html
# ============================================================
cat > "$DEMO_DIR/static/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<title>Глава 20 — Component Design Patterns</title>
<style>
  :root{--bg:#0f172a;--panel:#1e293b;--br:#334155;--tx:#e2e8f0;--mu:#94a3b8;--ac:#38bdf8;--ok:#22c55e;--er:#ef4444;--mo:ui-monospace,monospace}
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--tx);min-height:100vh;padding:2rem;display:flex;justify-content:center}
  .container{max-width:1000px;width:100%}
  h1{font-size:1.8rem;font-weight:600;text-align:center;margin-bottom:.35rem;background:linear-gradient(135deg,var(--ac),#a78bfa);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
  .sub{color:var(--mu);text-align:center;font-size:1rem;margin-bottom:.5rem}
  .hint{text-align:center;font-size:.75rem;color:#64748b;margin-bottom:1.5rem}
  .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:1rem}
  @media(max-width:800px){.grid{grid-template-columns:repeat(2,1fr)}}
  @media(max-width:500px){.grid{grid-template-columns:1fr}}
  .card{background:var(--panel);border:1px solid var(--br);border-radius:10px;padding:1.25rem;display:flex;flex-direction:column;transition:transform .15s}
  .card:hover{transform:translateY(-2px);border-color:var(--ac)}
  h3{font-size:.95rem;color:var(--ac);margin-bottom:.5rem}
  p{font-size:.75rem;color:var(--mu);margin-bottom:1rem;flex-grow:1;line-height:1.4}
  button{padding:.6rem;border-radius:6px;border:1px solid var(--ac);font-weight:600;cursor:pointer;background:rgba(56,189,248,.1);color:var(--ac);transition:.15s;font-size:.8rem}
  button:hover{background:var(--ac);color:#0c1222}
  button:disabled{opacity:.5;cursor:wait}
  .result{margin-top:.75rem;font-family:var(--mo);font-size:.7rem;color:var(--mu);background:#000;padding:.5rem;border-radius:4px;min-height:30px;word-break:break-all}
  .res-ok{color:var(--ok)}
  .res-err{color:var(--er)}
</style>
</head>
<body>
<div class="container">
  <h1>Component Design Patterns</h1>
  <p class="sub">Восемь архитектурных решений — в одном месте</p>
  <p class="hint">
    policy: требует <code>wasi:filesystem</code> preopen <code>./sandbox</code> ·
    drain: показывает версию, не in-flight
  </p>
  <div class="grid">
    <div class="card"><h3>1. Computational</h3><p>Чистая функция: вход → выход. Ни состояния, ни capabilities.</p><button onclick="run('/pattern/computational','r1')">Run</button><div class="result" id="r1">-</div></div>
    <div class="card"><h3>2. Plugin</h3><p>Один контракт — много реализаций. Выбор по имени/версии.</p><button onclick="run('/pattern/plugin','r2')">Run</button><div class="result" id="r2">-</div></div>
    <div class="card"><h3>3. Stateful</h3><p>Инстанс живёт между вызовами; счётчик сохраняется.</p><button onclick="run('/pattern/stateful','r3')">Run</button><div class="result" id="r3">-</div></div>
    <div class="card"><h3>4. Policy-Controlled</h3><p>Capability-контроль: guest видит только то, что дал host.</p><button onclick="run('/pattern/policy','r4')">Run</button><div class="result" id="r4">-</div></div>
    <div class="card"><h3>5. Resource</h3><p>Жизненный цикл объекта через handle: open → read → drop.</p><button onclick="run('/pattern/resource','r5')">Run</button><div class="result" id="r5">-</div></div>
    <div class="card"><h3>6. Pipeline</h3><p>Композиция: выход A — вход B. Один контракт, разные реализации.</p><button onclick="run('/pattern/pipeline','r6')">Run</button><div class="result" id="r6">-</div></div>
    <div class="card"><h3>7. Replaceable</h3><p>Hot-swap версии. In-flight запросы дорабатывают на старой.</p><button onclick="run('/pattern/drain','r7')">Run</button><div class="result" id="r7">-</div></div>
    <div class="card"><h3>8. Untrusted Extension</h3><p>Admission control по манифесту до загрузки чужого кода.</p><button onclick="run('/pattern/untrusted','r8')">Run</button><div class="result" id="r8">-</div></div>
  </div>
</div>
<script>
async function run(url,id){
  const el=document.getElementById(id);
  el.textContent='Running...';el.className='result';
  document.querySelectorAll('button').forEach(b=>b.disabled=true);
  try{
    const res=await fetch(url,{method:'POST'});
    const data=await res.json();
    if(data.error){el.innerHTML=`<span class="res-err">${data.error}</span>`}
    else{el.innerHTML=`<span class="res-ok">${data.result}</span>`}
  }catch(e){el.innerHTML=`<span class="res-err">Error: ${e}</span>`}
  finally{document.querySelectorAll('button').forEach(b=>b.disabled=false)}
}
</script>
</body>
</html>
HTML_EOF

# ============================================================
# [9/10] README + cargo check
# ============================================================
cat > "$DEMO_DIR/README.md" <<'EOF'
# Ch20 — Component Design Patterns

| # | Pattern        | Runtime        | Capabilities                 | Failure mode              |
|---|----------------|----------------|------------------------------|---------------------------|
| 1 | Computational  | `runtime`      | none                         | panic в guest             |
| 2 | Plugin         | `runtime_v15`  | none                         | несовместимый контракт    |
| 3 | Stateful       | `runtime_v7`   | none                         | новый Instance → сброс    |
| 4 | Policy         | `runtime_v9`   | `fs:read` preopen `./sandbox`| denied без preopen        |
| 5 | Resource       | `runtime_v13`  | none                         | drop ≠ close              |
| 6 | Pipeline       | `runtime_v18`  | none                         | A вернул Err → B не вызван|
| 7 | Replaceable    | `runtime_v16`  | none                         | drain ≠ interrupt         |
| 8 | Untrusted      | `runtime_v17`  | manifest + host allowlist    | denied до загрузки        |

## Version Compatibility

**Важно:** не указывайте `wit-bindgen` в `Cargo.toml` guest-компонентов.
`cargo-component` сам управляет этой зависимостью. Явное указание версии —
основная причина ошибок линковки guest-компонентов.
EOF

echo "=== [9/10] cargo check ==="
cargo check -p host --lib --quiet
cargo check -p demo-web-ui-ch20 --quiet

# ============================================================
# [10/10] Summary
# ============================================================
echo "=== [10/10] Готово ==="
cat <<MSG

✅ Глава 20 собрана.

Запуск:
  cargo run -p demo-web-ui-ch20 --release

Открыть:
  http://127.0.0.1:${PORT}

Ожидаемое поведение:
  • Computational, Plugin, Stateful, Resource, Pipeline, Drain, Untrusted —
    показывают конкретный результат (не ошибку) при условии, что
    компоненты предыдущих глав собраны.
  • Policy-Controlled вернёт read N bytes, если preopen ./sandbox активен;
    иначе — предупреждение от WASI (это тоже валидный эксперимент).
