wit_bindgen::generate!({
    path: "../../wit/text-engine-memory",
    world: "text-engine-memory",
});
use exports::docs::text_engine_memory::processor::Guest;
struct MemoryEngine;
impl Guest for MemoryEngine {
    fn allocate(mb: u32) -> Result<String, String> {
        let bytes = (mb as usize) * 1024 * 1024;
        // Пытаемся выделить память. Если лимит Store исчерпан,
        // произойдёт trap (out of memory), который Host перехватит.
        let mut vec: Vec<u8> = Vec::with_capacity(bytes);
        for i in 0..bytes {
            vec.push((i % 255) as u8);
        }
        Ok(format!("Allocated {} MB successfully.", mb))
    }
}
export!(MemoryEngine);
