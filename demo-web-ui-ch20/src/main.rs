// demo-web-ui-ch20/src/main.rs
//
// Глава 20: восемь архитектурных паттернов в одном визуальном каталоге.
//
// Уроки, зафиксированные в этом файле:
//   1. Пути к .wasm ищем в обоих target-каталогах (wasm32-wasip1 и wasm32-wasip2):
//      cargo-component может выдавать артефакт в любой из них.
//   2. Замыкания в spawn_blocking имеют явно указанный тип `anyhow::Result<_>`.
//      Иначе tail-expression вроде `rt.deploy_from_path(...)` (возвращает
//      Result<(), String>) не сойдётся с anyhow-ошибками из `?`-выражений выше.
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

/// Ищем .wasm в `wasm32-wasip1` (текущий дефолт cargo-component)
/// или `wasm32-wasip2` (если глава собиралась с --target wasm32-wasip2).
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

/// 1. Computational: чистая функция, без состояния и без capabilities.
async fn run_computational() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-component", "text-engine-component")?;
        let rt = ComputedRuntime::new(&path)?;
        Ok(rt.process("  HELLO  ")?)
    })
    .await;
    finish(r).await
}

/// 2. Plugin: один контракт — много реализаций, выбор по версии.
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

/// 3. Stateful: один Store, состояние переживает вызовы.
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

/// 4. Policy-controlled: guest видит только то, что дал host через preopen.
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

/// 5. Resource: handle + lifecycle (open → read → drop).
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

/// 6. Pipeline: A → B, выход одного компонента — вход следующего.
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

/// 7. Replaceable / drain: hot-swap версии, старые запросы дорабатывают.
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

/// 8. Untrusted extension: admission control по манифесту до загрузки.
///
/// ВАЖНО: `deploy_from_path` в `runtime_v17` возвращает `Result<(), String>`
/// (это сигнатура главы 17 — строка как ошибка, чтобы её мог прочитать
/// администратор без знания anyhow). Замыкание же возвращает
/// `anyhow::Result<String>` — конвертируем явно.
async fn run_untrusted() -> Json<Value> {
    let r = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
        let path = must_wasm("text-engine-deployable", "text-engine-deployable")?;
        let rt = DeployRuntime::new()?;
        let manifest = Manifest {
            name: "test".into(),
            version: "1.0".into(),
            required_capabilities: vec!["fs:read".into()],
        };
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