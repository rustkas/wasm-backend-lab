use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use host::runtime_v17::{Runtime, Manifest};

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

async fn deploy_valid(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    let manifest = Manifest {
        name: "text-engine".to_string(),
        version: "1.0.0".to_string(),
        required_capabilities: vec!["fs:read".to_string()],
    };

    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("components/text-engine-deployable/target/wasm32-wasip1/release/text_engine_deployable.wasm");

    match rt.deploy_from_path(&path, manifest) {
        Ok(_) => Json(json!({
            "status": "success",
            "message": "Component deployed and registered."
        })),
        Err(e) => Json(json!({ "status": "error", "message": e })),
    }
}

async fn deploy_invalid(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
) -> Json<Value> {
    let manifest = Manifest {
        name: "text-engine-bad".to_string(),
        version: "1.0.0".to_string(),
        required_capabilities: vec![], // Пустой список → Admission REJECT
    };

    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("components/text-engine-deployable/target/wasm32-wasip1/release/text_engine_deployable.wasm");

    match rt.deploy_from_path(&path, manifest) {
        Ok(_) => Json(json!({
            "status": "success",
            "message": "Unexpected success!"
        })),
        Err(e) => Json(json!({ "status": "error", "message": e })),
    }
}

async fn process(
    axum::extract::State(rt): axum::extract::State<Arc<Runtime>>,
    Json(p): Json<Value>,
) -> Json<Value> {
    let input = p["input"].as_str().unwrap_or("").to_string();
    match rt.process("text-engine", &input) {
        Ok(out) => Json(json!({ "output": out })),
        Err(e) => Json(json!({ "error": format!("{e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let runtime = Runtime::new()?;
    let app = Router::new()
        .route("/", get(index))
        .route("/deploy-valid", post(deploy_valid))
        .route("/deploy-invalid", post(deploy_invalid))
        .route("/process", post(process))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3016").await?;
    println!("🚀 Demo UI (Ch17): http://127.0.0.1:3016");
    axum::serve(listener, app).await?;
    Ok(())
}