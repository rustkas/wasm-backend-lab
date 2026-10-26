wit_bindgen::generate!({
    path: "../../wit/text-engine-crash",
    world: "text-engine-crash",
});
use exports::docs::text_engine_crash::processor::Guest;
use std::time::{Duration, Instant};
struct CrashEngine;
impl Guest for CrashEngine {
    fn long_task(ms: u32) -> String {
        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(ms as u64) {
            std::hint::black_box(0);
        }
        format!("Completed long task of {} ms", ms)
    }
    fn crash() -> String {
        panic!("Guest intentionally panicked!");
    }
}
export!(CrashEngine);
