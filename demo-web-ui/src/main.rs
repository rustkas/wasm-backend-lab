use axum::{response::Html, routing::get, Router};
use host::Runtime;

const INDEX_HTML: &str = include_str!("../static/index.html");

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let wasm_path = host::default_wasm_path();
    if !wasm_path.exists() {
        eprintln!("Error: WASM component not found at `{}`.", wasm_path.display());
        eprintln!(
            "Run `cd components/text-engine-component && cargo component build --release` first."
        );
        std::process::exit(1);
    }

    println!("Loading component: {}", wasm_path.display());
    let runtime = Runtime::new(&wasm_path)?;

    // host::http::router уже содержит POST /process; добавляем только GET /
    let app: Router = host::http::router(runtime).route("/", get(index));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3003").await?;
    println!("🚀 Demo UI: http://127.0.0.1:3003");
    axum::serve(listener, app).await?;
    Ok(())
}
