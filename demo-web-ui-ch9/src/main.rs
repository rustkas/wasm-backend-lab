use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v9::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn read_allowed(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    match tokio::task::spawn_blocking(move || rt.read_file("/sandbox/allowed.txt")).await {
        Ok(Ok(Ok(content))) => Json(json!({ "output": content })),
        Ok(Ok(Err(e))) => Json(json!({ "error": e })),
        _ => Json(json!({ "error": "internal_error" })),
    }
}

async fn read_secret(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    // Пытаемся прочитать файл, который лежит ЗА пределами ./sandbox
    // "/secret.txt" внутри WASI не существует, так как preopened_dir был только на ./sandbox
    match tokio::task::spawn_blocking(move || rt.read_file("/secret.txt")).await {
        Ok(Ok(Ok(content))) => Json(json!({ "output": content })),
        Ok(Ok(Err(e))) => {
            eprintln!("[guest-capability-error] {e}");
            Json(json!({ "error": "Permission denied (Capability boundary)" }))
        },
        _ => Json(json!({ "error": "internal_error" })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    // Важно: путь до .wasm внутри target/
    let wasm_path = manifest.parent().unwrap()
        .join("components/text-engine-secure/target/wasm32-wasip1/release/text_engine_secure.wasm");

    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!("Run `cd components/text-engine-secure && cargo component build --release` first.");
        std::process::exit(1);
    }

    let runtime = Runtime::new(&wasm_path)?;

    let app = Router::new()
        .route("/", get(index))
        .route("/allowed", post(read_allowed))
        .route("/secret", post(read_secret))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3008").await?;
    println!("🚀 Demo UI (Ch9): http://127.0.0.1:3008");
    axum::serve(listener, app).await?;
    Ok(())
}
