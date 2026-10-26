use axum::{response::Html, routing::{get, post}, Json, Router, extract::Path};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v11::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn start_task(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    let id = rt.start_task();
    let rt_clone = rt.clone();
    let id_clone = id.clone();
    
    tokio::task::spawn_blocking(move || {
        let res = rt_clone.run_long_task(&id_clone, 5000);
        match res {
            Ok(msg) => println!("[task {}] {msg}", id_clone),
            Err(e) => println!("[task {}] FAILED: {e:?}", id_clone),
        }
    });

    Json(json!({ "task_id": id }))
}

async fn cancel_task(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Path(id): Path<String>,
) -> Json<Value> {
    let cancelled = rt.cancel_task(&id);
    if cancelled {
        Json(json!({ "status": "cancelled" }))
    } else {
        Json(json!({ "error": "task not found" }))
    }
}

async fn crash_guest(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.run_crash()).await {
        Ok(Ok(_)) => Json(json!({ "output": "unexpected success" })),
        Ok(Err(e)) => {
            eprintln!("[crash] {e:?}");
            Json(json!({ "error": "Guest panicked (Trap)" }))
        },
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-crash/target/wasm32-wasip1/release/text_engine_crash.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/start", post(start_task))
        .route("/cancel/{id}", post(cancel_task)) // ← ИСПРАВЛЕНО ЗДЕСЬ
        .route("/crash", post(crash_guest))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3010").await?;
    println!("🚀 Demo UI (Ch11): http://127.0.0.1:3010");
    axum::serve(listener, app).await?;
    Ok(())
}