use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v10::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn allocate_small(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.allocate(32)).await {
        Ok(Ok(Ok(msg))) => Json(json!({ "output": msg })),
        Ok(Ok(Err(e))) => Json(json!({ "error": format!("Logical error: {e}") })),
        Ok(Err(e)) => Json(json!({ "error": format!("Runtime trap: {e}") })),
        Err(e) => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

async fn allocate_big(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.allocate(128)).await {
        Ok(Ok(Ok(msg))) => Json(json!({ "output": msg })),
        Ok(Ok(Err(e))) => {
            eprintln!("[guest-memory-error] logical: {e}");
            Json(json!({ "error": "Guest logical error" }))
        },
        Ok(Err(e)) => {
            let err_str = format!("{:?}", e);
            eprintln!("[guest-memory-trap] {err_str}");
            // Перехватываем trap от OOM
            if err_str.contains("unreachable") || err_str.contains("out of memory") || err_str.contains("memory") {
                Json(json!({ "error": "Memory limit exceeded (64MB cap)" }))
            } else {
                Json(json!({ "error": format!("Runtime trap: {e}") }))
            }
        },
        Err(e) => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-memory/target/wasm32-wasip1/release/text_engine_memory.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/small", post(allocate_small))
        .route("/big", post(allocate_big))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3009").await?;
    println!("🚀 Demo UI (Ch10): http://127.0.0.1:3009");
    axum::serve(listener, app).await?;
    Ok(())
}
