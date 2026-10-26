use axum::{response::Html, routing::{get, post}, Json, Router, extract::State};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use host::runtime_v21::{Runtime, Manifest};

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

fn wasm_path(ver: &str) -> PathBuf {
    // Исправление E0716: создаем владеющий PathBuf, чтобы избежать drop временного значения
    let base = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf();
    let stem = format!("managed_runtime_v{}", ver);
    for target in ["wasm32-wasip2", "wasm32-wasip1"] {
        let p = base.join(format!("components/managed-runtime-v{}/target/{}/release/{}.wasm", ver, target, stem));
        if p.exists() { return p; }
    }
    panic!("WASM not found for version {}", ver);
}

async fn setup_components(rt: Arc<Runtime>) {
    let manifest1 = Manifest {
        name: "demo-text".into(),
        version: "1.0".into(),
        required_capabilities: vec!["fs:read".into()],
    };
    rt.register(&wasm_path("1"), manifest1).unwrap();
}

async fn invoke(State(rt): State<Arc<Runtime>>, Json(payload): Json<Value>) -> Json<Value> {
    let input = payload["input"].as_str().unwrap_or("hello");
    match rt.invoke("demo-text", input) {
        Ok(res) => Json(json!({ "result": res })),
        Err(e) => Json(json!({ "error": e.to_string() })),
    }
}

async fn swap(State(rt): State<Arc<Runtime>>) -> Json<Value> {
    match rt.hot_swap("demo-text", &wasm_path("2")) {
        Ok(_) => Json(json!({ "result": "Hot-swap successful to v2" })),
        Err(e) => Json(json!({ "error": e.to_string() })),
    }
}

async fn metrics(State(rt): State<Arc<Runtime>>) -> String {
    rt.get_metrics()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let rt = Arc::new(Runtime::new()?);
    setup_components(rt.clone()).await;

    let app = Router::new()
        .route("/", get(index))
        .route("/api/invoke", post(invoke))
        .route("/api/swap", post(swap))
        .route("/metrics", get(metrics))
        .with_state(rt);

    let addr = "127.0.0.1:3021";
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("🚀 Managed Runtime (Ch21): http://{}", addr);
    axum::serve(listener, app).await?;
    Ok(())
}
