wit_bindgen::generate!({
    path: "../../wit/text-engine-stream",
    world: "text-engine-stream",
});

use exports::docs::text_engine_stream::processor::{Guest, GuestChunkReader, ChunkReader};
use std::cell::Cell;

struct MyChunkReader {
    total_size: u32,
    offset: Cell<u32>,
    chunk_size: u32,
}

impl GuestChunkReader for MyChunkReader {
    fn read_chunk(&self) -> Option<Vec<u8>> {
        let offset = self.offset.get();
        if offset >= self.total_size {
            return None;
        }
        let remaining = self.total_size - offset;
        let size = std::cmp::min(self.chunk_size, remaining);
        let mut chunk = vec![0u8; size as usize];
        for i in 0..size {
            chunk[i as usize] = ((offset + i) % 256) as u8;
        }
        self.offset.set(offset + size);
        Some(chunk)
    }
}

struct StreamEngine;

impl Guest for StreamEngine {
    type ChunkReader = MyChunkReader;

    fn process_list(data: Vec<u8>) -> u32 {
        data.iter().map(|&b| b as u32).sum()
    }

    fn open_reader(total_size: u32) -> ChunkReader {
        ChunkReader::new(MyChunkReader {
            total_size,
            offset: Cell::new(0),
            chunk_size: 1024 * 1024,
        })
    }
}

export!(StreamEngine);
