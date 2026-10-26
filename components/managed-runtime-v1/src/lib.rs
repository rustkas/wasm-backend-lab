//! Managed Runtime V1 — версия 1
wit_bindgen::generate!({
    path: "wit",
    world: "managed-runtime",
});

struct Processor;
impl exports::docs::managed_runtime::processor::Guest for Processor {
    fn process(input: String) -> Result<String, String> {
        Ok(format!("[V1] {}", input.to_uppercase()))
    }
    fn get_version() -> String {
        "1".to_string()
    }
}
export!(Processor);
