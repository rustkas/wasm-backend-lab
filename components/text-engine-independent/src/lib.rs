wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});

struct IndependentEngine;
impl exports::docs::text_engine::processor::Guest for IndependentEngine {
    fn process(input: String) -> String {
        format!("{} [verified]", input.to_uppercase())
    }
}
export!(IndependentEngine);
