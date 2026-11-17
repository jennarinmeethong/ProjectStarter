//! Contract every `ArtifactStore` adapter must satisfy (Liskov: adapters are interchangeable behind the
//! port). The in-memory adapter runs it in the unit suite; datastore adapters run it against real
//! containers (`--features integration`).

use std::future::Future;

use application::{ArtifactStore, PortError};

/// Reads back what an adapter stored, so the contract can check it.
pub trait ReadBack {
    fn read_back(&self, key: &str) -> impl Future<Output = Result<Option<String>, PortError>> + Send;
}

/// Checks the whole contract against one store.
pub async fn check_contract<S: ArtifactStore + ReadBack + Sync>(store: &S) -> Result<(), PortError> {
    returns_a_key_that_reads_back_the_content(store).await?;
    is_idempotent_per_job(store).await?;
    keeps_different_jobs_apart(store).await
}

async fn returns_a_key_that_reads_back_the_content<S: ArtifactStore + ReadBack + Sync>(
    store: &S,
) -> Result<(), PortError> {
    let key = store.save("contract-1", "id\n1\n").await?;
    assert_eq!(store.read_back(&key).await?.as_deref(), Some("id\n1\n"));
    Ok(())
}

async fn is_idempotent_per_job<S: ArtifactStore + ReadBack + Sync>(store: &S) -> Result<(), PortError> {
    let first = store.save("contract-2", "old").await?;
    let second = store.save("contract-2", "new").await?;
    assert_eq!(first, second);
    assert_eq!(store.read_back(&second).await?.as_deref(), Some("new"));
    Ok(())
}

async fn keeps_different_jobs_apart<S: ArtifactStore + ReadBack + Sync>(store: &S) -> Result<(), PortError> {
    let a = store.save("contract-3a", "a").await?;
    let b = store.save("contract-3b", "b").await?;
    assert_ne!(a, b);
    assert_eq!(store.read_back(&a).await?.as_deref(), Some("a"));
    assert_eq!(store.read_back(&b).await?.as_deref(), Some("b"));
    Ok(())
}
