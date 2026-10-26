wit_bindgen::generate!({
    path: "../../wit/text-engine-observe",
    world: "text-engine-observe",
});

use exports::docs::text_engine_observe::processor::Guest;

struct ObserveEngine;

impl Guest for ObserveEngine {
    fn process(input: String) -> String {
        // В WASI эти вызовы перехватываются Host-ом
        println!("[guest-log] Starting processing");
        println!("[guest-log] Input length: {}", input.len());
        
        let result = input.to_uppercase();
        
        println!("[guest-log] Finished processing successfully");
        result
    }
}
export!(ObserveEngine);
