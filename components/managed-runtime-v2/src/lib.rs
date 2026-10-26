//! Managed Runtime V2 — версия 2
wit_bindgen::generate!({
    path: "wit",
    world: "managed-runtime",
});

struct Processor;
impl exports::docs::managed_runtime::processor::Guest for Processor {
    fn process(input: String) -> Result<String, String> {
        Ok(format!("[V2] {}", input.to_uppercase()))
    }
    fn get_version() -> String {
        "2".to_string()
    }
}
export!(Processor);
