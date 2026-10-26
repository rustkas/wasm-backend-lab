# wasm-backend-lab

**Companion codebase for the book "WebAssembly Backend by Doing"**

This repository contains the complete, working source code for the `wasm-backend-lab` project. The project is built iteratively throughout the book to demonstrate how to build a robust backend around WebAssembly Components.

**Stack:** Rust · Axum · Wasmtime · Component Model (WIT) · WASI Preview 2

---

## 📂 Repository Structure

The workspace is organized into logical blocks that grow as you progress through the chapters:

- **`host/`** — The core backend application (Axum + Wasmtime). It contains multiple runtime modules (`runtime.rs`, `runtime_v6.rs` ... `runtime_v22.rs`) that represent the architectural evolution described in each chapter.
- **`components/`** — Guest WebAssembly components written in Rust. Examples include `text-engine-*`, `managed-runtime-v1`, `managed-runtime-v2`, etc.
- **`wit/`** — WebAssembly Interface Type (WIT) contracts that define the strict boundaries between the host and the guest components.
- **`demo-web-ui-ch*`** — Visual, interactive demos for each chapter (from Chapter 6 to 22). Each demo is a self-contained Axum web server.
- **`scripts/`** — Automation scripts (`setup-ch*.sh`) that build components, generate boilerplate, and set up the environment for a specific chapter without breaking previous work.
- **`tests/`** — Integration and contract tests that ensure the components and runtimes behave as expected.

---

## 🚀 Quick Start

### Prerequisites

Ensure you have the following tools installed:

1. **Rust toolchain** (version defined in `rust-toolchain.toml`).
2. **`cargo-component`**:
   ```bash
   cargo install cargo-component --locked