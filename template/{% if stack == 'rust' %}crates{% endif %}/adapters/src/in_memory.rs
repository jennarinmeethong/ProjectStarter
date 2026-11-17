//! `ArtifactStore` that keeps artifacts in memory (tests, demos).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use application::{ArtifactStore, PortError};

/// Keeps artifacts in a map. Cheap to clone; clones share the same map.
#[derive(Debug, Default, Clone)]
pub struct InMemoryArtifactStore {
    files: Arc<Mutex<HashMap<String, String>>>,
}

impl InMemoryArtifactStore {
    /// Returns the content stored under `key`, if any.
    pub fn read(&self, key: &str) -> Result<Option<String>, PortError> {
        let files = self.files.lock().map_err(|_| PortError::from("in-memory store lock poisoned"))?;
        Ok(files.get(key).cloned())
    }
}

impl InMemoryArtifactStore {
    fn save_now(&self, job_id: &str, content: &str) -> Result<String, PortError> {
        let key = format!("exports/{job_id}.csv");
        let mut files = self.files.lock().map_err(|_| PortError::from("in-memory store lock poisoned"))?;
        files.insert(key.clone(), content.to_owned());
        Ok(key)
    }
}

impl ArtifactStore for InMemoryArtifactStore {
    fn save(&self, job_id: &str, content: &str) -> impl Future<Output = Result<String, PortError>> + Send {
        std::future::ready(self.save_now(job_id, content))
    }
}
