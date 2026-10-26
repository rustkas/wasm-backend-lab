wit_bindgen::generate!({
    path: "../../wit/text-engine-advanced",
    world: "text-engine-advanced",
});

use exports::docs::text_engine_advanced::processor::{Guest, TextError, TextRequest};

struct AdvancedEngine;

impl Guest for AdvancedEngine {
    fn process_string(input: String) -> String {
        text_engine::normalize_text(&input)
    }

    fn process_record(req: TextRequest) -> Result<String, TextError> {
        if req.content.is_empty() {
            return Err(TextError::EmptyInput);
        }
        match req.mode.as_str() {
            "upper"     => Ok(req.content.to_uppercase()),
            "lower"     => Ok(req.content.to_lowercase()),
            "normalize" => Ok(text_engine::normalize_text(&req.content)),
            other       => Err(TextError::UnknownMode(other.to_string())),
        }
    }

    fn process_bytes(data: Vec<u8>) -> Result<String, TextError> {
        if data.is_empty() {
            return Err(TextError::EmptyInput);
        }
        match String::from_utf8(data) {
            Ok(s)  => Ok(text_engine::normalize_text(&s)),
            Err(e) => Err(TextError::InvalidUtf8(e.to_string())),
        }
    }
}

export!(AdvancedEngine);
