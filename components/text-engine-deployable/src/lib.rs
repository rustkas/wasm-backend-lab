wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});

struct TextEngine;
impl exports::docs::text_engine::processor::Guest for TextEngine {
    fn process(input: String) -> String {
        input.to_lowercase()
    }
}
export!(TextEngine);
