wit_bindgen::generate!({
    path: "../../wit/text-engine-resource",
    world: "text-engine-resource",
});

use exports::docs::text_engine_resource::processor::{Guest, GuestDocument, Document};
use std::cell::Cell;

struct MyDocument {
    content: String,
    closed: Cell<bool>,
}

impl GuestDocument for MyDocument {
    fn get_content(&self) -> String {
        if self.closed.get() {
            panic!("Use after close!");
        }
        self.content.clone()
    }

    fn close(&self) {
        self.closed.set(true);
    }
}

struct ResourceEngine;

impl Guest for ResourceEngine {
    type Document = MyDocument;

    fn open(name: String) -> Result<Document, String> {
        Ok(Document::new(MyDocument {
            content: format!("Content of {}", name),
            closed: Cell::new(false),
        }))
    }
}

export!(ResourceEngine);
