use axum::{response::Html, routing::{get, post}, Json, Router, extract::Path};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v15::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn process(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Json(p): Json<Value>) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    
    // ИСПРАВЛЕНИЕ: Получаем версию (u8) ДО того, как rt будет перемещен в замыкание.
    // u8 реализует Copy, поэтому мы можем использовать её после await.
    let version = rt.get_active_version();
    
    match tokio::task::spawn_blocking(move || rt.process(&input)).await {
        Ok(Ok(output)) => Json(json!({ "output": output, "version": version })),
        Ok(Err(e)) => Json(json!({ "error": format!("{e}") })),
        Err(e) => Json(json!({ "error": format!("join: {e}") })),
    }
}

async fn switch(axum::extract::State(rt): axum::extract::State<Arc<Runtime>>, Path(ver): Path<u8>) -> Json<Value> {
    rt.switch_version(ver);
    Json(json!({ "status": "switched", "version": ver }))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let v1 = manifest.parent().unwrap().join("components/text-engine-component/target/wasm32-wasip1/release/text_engine_component.wasm");
    let v2 = manifest.parent().unwrap().join("components/text-engine-v2/target/wasm32-wasip1/release/text_engine_v2.wasm");
    
    if !v1.exists() || !v2.exists() { std::process::exit(1); }

    let runtime = Runtime::new(&v1, &v2)?;
    let app = Router::new()
        .route("/", get(index))
        .route("/process", post(process))
        .route("/switch/{ver}", post(switch))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3014").await?;
    println!("🚀 Demo UI (Ch15): http://127.0.0.1:3014");
    axum::serve(listener, app).await?;
    Ok(())
}