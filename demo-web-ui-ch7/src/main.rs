use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v7::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn stateless_increment(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.increment_stateless()).await {
        Ok(Ok(val)) => Json(json!({ "value": val })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn stateful_increment(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.increment_stateful()).await {
        Ok(Ok(val)) => Json(json!({ "value": val })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn stateful_get(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.get_stateful()).await {
        Ok(Ok(val)) => Json(json!({ "value": val })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn stateful_reset(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.reset_stateful()).await {
        Ok(Ok(())) => Json(json!({ "status": "reset" })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-stateful/target/wasm32-wasip1/release/text_engine_stateful.wasm");

    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!("Run `cd components/text-engine-stateful && cargo component build --release` first.");
        std::process::exit(1);
    }

    println!("Loading component: {}", wasm_path.display());
    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/stateless/increment", post(stateless_increment))
        .route("/stateful/increment", post(stateful_increment))
        .route("/stateful/get", get(stateful_get))
        .route("/stateful/reset", post(stateful_reset))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3006").await?;
    println!("🚀 Demo UI (Ch7): http://127.0.0.1:3006");
    axum::serve(listener, app).await?;
    Ok(())
}
