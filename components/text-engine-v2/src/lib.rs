wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});

struct TextEngineV2;

impl exports::docs::text_engine::processor::Guest for TextEngineV2 {
    fn process(input: String) -> String {
        // В отличие от v1 (которая делает to_lowercase), 
        // v2 переводит в верхний регистр и добавляет метку.
        format!("[V2] {}", input.to_uppercase())
    }
}

export!(TextEngineV2);
