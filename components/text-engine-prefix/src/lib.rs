wit_bindgen::generate!({
    path: "../../wit/text-engine",
    world: "text-engine",
});
struct PrefixEngine;
impl exports::docs::text_engine::processor::Guest for PrefixEngine {
    fn process(input: String) -> String {
        format!("pre_{}", input) // Изменено на нижний регистр!
    }
}
export!(PrefixEngine);
