use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v13::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn open_doc(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Json(p): Json<Value>) -> Json<Value> {
    let name = p["name"].as_str().unwrap_or("test.txt").to_string();
    match tokio::task::spawn_blocking(move || rt.open_document(&name)).await {
        Ok(Ok(_)) => Json(json!({ "output": "Document opened successfully." })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn read_doc(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.get_content()).await {
        Ok(Ok(content)) => Json(json!({ "output": content })),
        Ok(Err(e)) => {
            eprintln!("[guest-resource-error] {e:?}");
            Json(json!({ "error": "Trap: Use after close!" }))
        },
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn close_doc(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.close_document()).await {
        Ok(Ok(_)) => Json(json!({ "output": "Document closed." })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-resource/target/wasm32-wasip1/release/text_engine_resource.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/open", post(open_doc))
        .route("/read", post(read_doc))
        .route("/close", post(close_doc))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3012").await?;
    println!("🚀 Demo UI (Ch13): http://127.0.0.1:3012");
    axum::serve(listener, app).await?;
    Ok(())
}
