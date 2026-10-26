use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v6::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process_string(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    match tokio::task::spawn_blocking(move || rt.process_string(&input)).await {
        Ok(Ok(out)) => Json(json!({ "output": out })),
        Ok(Err(e))  => Json(json!({ "error": format!("{e}") })),
        Err(e)      => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn process_record(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let content = p["content"].as_str().unwrap_or("").to_string();
    let mode    = p["mode"].as_str().unwrap_or("").to_string();
    match tokio::task::spawn_blocking(move || rt.process_record(&content, &mode)).await {
        Ok(Ok(Ok(out))) => Json(json!({ "output": out })),
        Ok(Ok(Err(e)))  => {
            eprintln!("[guest-record-error] {e}");
            Json(json!({ "error": "guest_error",
                         "kind":  error_kind(&e),
                         "reason":"see server log for details" }))
        }
        Ok(Err(e))      => Json(json!({ "error": format!("host: {e}") })),
        Err(e)          => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn process_bytes(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let data: Vec<u8> = p["bytes"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_u64().map(|n| n as u8)).collect())
        .unwrap_or_default();
    match tokio::task::spawn_blocking(move || rt.process_bytes(&data)).await {
        Ok(Ok(Ok(out))) => Json(json!({ "output": out })),
        Ok(Ok(Err(e)))  => {
            eprintln!("[guest-bytes-error] {e}");
            Json(json!({ "error": "guest_error",
                         "kind":  error_kind(&e),
                         "reason":"see server log for details" }))
        }
        Ok(Err(e))      => Json(json!({ "error": format!("host: {e}") })),
        Err(e)          => Json(json!({ "error": format!("join: {e}") })),
    }
}

// Извлекаем "kind" из debug-строки TextError::Variant(...)
fn error_kind(debug: &str) -> &'static str {
    if debug.contains("InvalidUtf8")  { "invalid_utf8"  }
    else if debug.contains("EmptyInput")   { "empty_input"   }
    else if debug.contains("UnknownMode")  { "unknown_mode"  }
    else                                   { "unknown"       }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-advanced/target/wasm32-wasip1/release/text_engine_advanced.wasm");

    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!("Run `cd components/text-engine-advanced && cargo component build --release` first.");
        std::process::exit(1);
    }

    println!("Loading component: {}", wasm_path.display());
    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/string", post(process_string))
        .route("/record", post(process_record))
        .route("/bytes",  post(process_bytes))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3005").await?;
    println!("🚀 Demo UI (Ch6): http://127.0.0.1:3005");
    axum::serve(listener, app).await?;
    Ok(())
}
