wit_bindgen::generate!({
    path: "../../wit/text-engine-stateful",
    world: "text-engine-stateful",
});

use exports::docs::text_engine_stateful::processor::Guest;
use std::sync::atomic::{AtomicU32, Ordering};

// Глобальное состояние в WASM linear memory.
// Оно сохраняется до тех пор, пока жив Store (и инстанс компонента).
static COUNTER: AtomicU32 = AtomicU32::new(0);

struct StatefulEngine;

impl Guest for StatefulEngine {
    fn increment() -> u32 {
        COUNTER.fetch_add(1, Ordering::SeqCst) + 1
    }

    fn get() -> u32 {
        COUNTER.load(Ordering::SeqCst)
    }

    fn reset() {
        COUNTER.store(0, Ordering::SeqCst);
    }
}

export!(StatefulEngine);
