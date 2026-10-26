use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v12::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Json(p): Json<Value>) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    
    match tokio::task::spawn_blocking(move || rt.process_observed(&input)).await {
        Ok(Ok(res)) => Json(json!({
            "output": res.output,
            "logs": res.logs,
            "metrics": {
                "duration_us": res.duration.as_micros(),
                "duration_ms": res.duration.as_secs_f64() * 1000.0
            }
        })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-observe/target/wasm32-wasip1/release/text_engine_observe.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/process", post(process))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3011").await?;
    println!("🚀 Demo UI (Ch12): http://127.0.0.1:3011");
    axum::serve(listener, app).await?;
    Ok(())
}
