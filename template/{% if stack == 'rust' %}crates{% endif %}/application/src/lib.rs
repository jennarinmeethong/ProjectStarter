//! Use cases. The application reaches the outside world only through ports it defines, which adapters
//! implement and bootstrap wires (ADR 0001).

use std::error::Error;
use std::fmt;
use std::future::Future;

use domain::{CompleteError, Ready, Running};

/// Error raised by an adapter behind a port.
pub type PortError = Box<dyn Error + Send + Sync>;

/// Port: defined here, implemented in adapters, wired in bootstrap.
pub trait ArtifactStore {
    /// Stores the content for a job and returns its key. Saving the same job again replaces it.
    fn save(&self, job_id: &str, content: &str) -> impl Future<Output = Result<String, PortError>> + Send;
}

/// Why an export could not be completed.
#[derive(Debug)]
pub enum CompleteExportError {
    /// The store failed.
    Store(PortError),
    /// The domain rejected the transition.
    Domain(CompleteError),
}

impl fmt::Display for CompleteExportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Store(error) => write!(f, "save artifact: {error}"),
            Self::Domain(error) => write!(f, "complete export: {error}"),
        }
    }
}

impl Error for CompleteExportError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Store(error) => Some(error.as_ref()),
            Self::Domain(error) => Some(error),
        }
    }
}

/// Stores the export content and completes the running job.
pub async fn complete_export<S: ArtifactStore + Sync>(
    store: &S,
    job: Running,
    content: &str,
) -> Result<Ready, CompleteExportError> {
    let key = store.save(job.id(), content).await.map_err(CompleteExportError::Store)?;
    domain::complete(job, &key).map_err(CompleteExportError::Domain)
}
