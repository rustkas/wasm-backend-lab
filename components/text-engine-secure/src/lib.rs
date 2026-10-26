wit_bindgen::generate!({
    path: "../../wit/text-engine-secure",
    world: "text-engine-secure",
});
use exports::docs::text_engine_secure::processor::Guest;
struct SecureEngine;
impl Guest for SecureEngine {
    fn read_file(path: String) -> Result<String, String> {
        match std::fs::read_to_string(&path) {
            Ok(content) => Ok(content),
            Err(e) => Err(format!("Failed to read: {}", e)),
        }
    }
}
export!(SecureEngine);
