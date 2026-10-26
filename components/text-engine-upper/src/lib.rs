wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});
struct UpperEngine;
impl exports::docs::text_engine::processor::Guest for UpperEngine {
    fn process(input: String) -> String {
        input.to_uppercase()
    }
}
export!(UpperEngine);
