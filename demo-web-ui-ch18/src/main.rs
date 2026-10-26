use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v18::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Json(p): Json<Value>) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    let step1 = p["step1"].as_str().unwrap_or("upper").to_string();
    let step2 = p["step2"].as_str().unwrap_or("prefix").to_string();
    
    match tokio::task::spawn_blocking(move || rt.process_pipeline(&step1, &step2, &input)).await {
        Ok(Ok(output)) => Json(json!({ "output": output })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let upper = manifest.parent().unwrap().join("components/text-engine-upper/target/wasm32-wasip1/release/text_engine_upper.wasm");
    let prefix = manifest.parent().unwrap().join("components/text-engine-prefix/target/wasm32-wasip1/release/text_engine_prefix.wasm");
    
    if !upper.exists() || !prefix.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&upper, &prefix)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/process", post(process))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3017").await?;
    println!("🚀 Demo UI (Ch18): http://127.0.0.1:3017");
    axum::serve(listener, app).await?;
    Ok(())
}
