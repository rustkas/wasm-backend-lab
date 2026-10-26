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
