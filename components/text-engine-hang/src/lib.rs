wit_bindgen::generate!({
    path: "../../wit/text-engine-hang",
    world: "text-engine-hang",
});
use exports::docs::text_engine_hang::processor::Guest;
struct HangEngine;
impl Guest for HangEngine {
    fn process(iterations: u32) -> String {
        if iterations == 0 {
            let mut i: u64 = 0;
            loop {
                i = i.wrapping_add(1);
                std::hint::black_box(i);
            }
        } else {
            let mut sum: u64 = 0;
            for i in 0..iterations {
                sum = sum.wrapping_add(i as u64);
                std::hint::black_box(sum);
            }
            format!("Completed {} iterations, sum={}", iterations, sum)
        }
    }
}
export!(HangEngine);
