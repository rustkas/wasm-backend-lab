use axum::{response::Html, routing::{get, post}, Json, Router, extract::Path};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v16::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    // Симулируем долгий запрос (3 секунды)
    let result = tokio::task::spawn_blocking(move || rt.process(3000)).await;
    match result {
        Ok(Ok((_msg, version))) => Json(json!({ "version": version, "status": "completed" })),
        _ => Json(json!({ "error": "failed" })),
    }
}

async fn swap(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Path(ver): Path<u8>) -> Json<Value> {
    rt.swap_version(ver);
    Json(json!({ "status": "swapped", "active_version": ver }))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let v1 = manifest.parent().unwrap().join("components/text-engine-slow-v1/target/wasm32-wasip1/release/text_engine_slow_v1.wasm");
    let v2 = manifest.parent().unwrap().join("components/text-engine-slow-v2/target/wasm32-wasip1/release/text_engine_slow_v2.wasm");
    
    if !v1.exists() || !v2.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&v1, &v2)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/process", post(process))
        .route("/swap/{ver}", post(swap))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3015").await?;
    println!("🚀 Demo UI (Ch16): http://127.0.0.1:3015");
    axum::serve(listener, app).await?;
    Ok(())
}
