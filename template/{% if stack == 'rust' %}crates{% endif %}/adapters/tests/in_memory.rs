mod common;

use std::future::Future;

use adapters::in_memory::InMemoryArtifactStore;
use application::PortError;

impl common::ReadBack for InMemoryArtifactStore {
    fn read_back(&self, key: &str) -> impl Future<Output = Result<Option<String>, PortError>> + Send {
        std::future::ready(self.read(key))
    }
}

#[tokio::test]
async fn in_memory_store_satisfies_the_contract() -> Result<(), PortError> {
    common::check_contract(&InMemoryArtifactStore::default()).await
}
