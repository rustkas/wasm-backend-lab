use axum::{response::Html, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;

const INDEX_HTML: &str = include_str!("../static/index.html");
async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn run_test() -> Json<Value> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let src = root.join("components/text-engine-independent");
    let backup = root.join("target/ch19-backup/text-engine-independent");

    // Перемещаем исходники в target/ (вне воркспейса)
    std::fs::create_dir_all(backup.parent().unwrap()).ok();
    let moved = std::fs::rename(&src, &backup).is_ok();

    let root_clone = root.clone();
    let output = tokio::task::spawn_blocking(move || {
        Command::new("cargo")
            .args(["test", "--test", "contract_v19", "--", "--nocapture"])
            .current_dir(root_clone.join("host"))
            .output()
    }).await.expect("join");

    // Всегда возвращаем исходники на место
    if moved {
        let _ = std::fs::rename(&backup, &src);
    }

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let success = out.status.success();
            Json(json!({ "success": success, "log": stdout }))
        }
        Err(e) => Json(json!({ "success": false, "log": format!("Failed to run cargo: {e}") })),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let app = Router::new()
        .route("/", get(index))
        .route("/run-test", post(run_test));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3018").await?;
    println!("🚀 Demo UI (Ch19): http://127.0.0.1:3018");
    axum::serve(listener, app).await?;
    Ok(())
}
