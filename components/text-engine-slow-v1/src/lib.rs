wit_bindgen::generate!({
    path: "../../wit/text-engine-slow",
    world: "text-engine-slow",
});
struct SlowEngine;
impl exports::docs::text_engine_slow::processor::Guest for SlowEngine {
    fn process(ms: u32) -> String {
        std::thread::sleep(std::time::Duration::from_millis(ms as u64));
        "done".to_string()
    }
}
export!(SlowEngine);
