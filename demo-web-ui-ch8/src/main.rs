use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v8::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

fn format_err(e: anyhow::Error) -> String {
    let s = format!("{e:?}");
    if s.contains("interrupt") { "Error: Timeout (Epoch interrupted)".to_string() }
    else if s.contains("fuel") { "Error: Fuel exhausted".to_string() }
    else { format!("Error: {}", s) }
}

async fn run_fuel(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let iterations = p["iterations"].as_u64().unwrap_or(0) as u32;
    let start = std::time::Instant::now();
    match tokio::task::spawn_blocking(move || rt.run_with_fuel(iterations, 100_000_000)).await {
        Ok(Ok(out)) => Json(json!({ "output": out, "time_ms": start.elapsed().as_millis() })),
        Ok(Err(e))  => Json(json!({ "error": format_err(e), "time_ms": start.elapsed().as_millis() })),
        Err(e)      => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

async fn run_epoch(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let iterations = p["iterations"].as_u64().unwrap_or(0) as u32;
    let start = std::time::Instant::now();
    match tokio::task::spawn_blocking(move || rt.run_with_epoch(iterations)).await {
        Ok(Ok(out)) => Json(json!({ "output": out, "time_ms": start.elapsed().as_millis() })),
        Ok(Err(e))  => Json(json!({ "error": format_err(e), "time_ms": start.elapsed().as_millis() })),
        Err(e)      => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

async fn run_no_limit(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let iterations = p["iterations"].as_u64().unwrap_or(0) as u32;
    let start = std::time::Instant::now();
    // 10 миллиардов топлива — это надолго зависнет
    match tokio::task::spawn_blocking(move || rt.run_with_fuel(iterations, 10_000_000_000)).await {
        Ok(Ok(out)) => Json(json!({ "output": out, "time_ms": start.elapsed().as_millis() })),
        Ok(Err(e))  => Json(json!({ "error": format_err(e), "time_ms": start.elapsed().as_millis() })),
        Err(e)      => Json(json!({ "error": format!("Join error: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-hang/target/wasm32-wasip1/release/text_engine_hang.wasm");
    if !wasm_path.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&wasm_path)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/run_fuel", post(run_fuel))
        .route("/run_epoch", post(run_epoch))
        .route("/run_no_limit", post(run_no_limit))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3007").await?;
    println!("🚀 Demo UI (Ch8): http://127.0.0.1:3007");
    axum::serve(listener, app).await?;
    Ok(())
}
