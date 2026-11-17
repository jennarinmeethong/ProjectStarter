//! Export job states, invariants and transitions. No I/O and no dependencies (ADR 0001).
//!
//! Illegal states are unrepresentable: only a running job can complete, and a ready job always has an
//! artifact key. Fields are private, so values only come from the transitions below.

use std::fmt;

/// A job in any state. Matches over it must name every variant (`clippy::wildcard_enum_match_arm`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExportJob {
    Queued(Queued),
    Running(Running),
    Ready(Ready),
    Failed(Failed),
}

/// A job waiting to start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Queued {
    id: String,
}

/// A job in progress.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Running {
    id: String,
}

/// A finished job with its artifact key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ready {
    id: String,
    artifact_key: String,
}

/// A job that stopped with a reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failed {
    id: String,
    reason: String,
}

impl Queued {
    /// Creates a queued job.
    pub fn new(id: impl Into<String>) -> Self {
        Self { id: id.into() }
    }

    /// The job id.
    pub fn id(&self) -> &str {
        &self.id
    }
}

impl Running {
    /// The job id.
    pub fn id(&self) -> &str {
        &self.id
    }
}

impl Ready {
    /// The job id.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Where the export was stored.
    pub fn artifact_key(&self) -> &str {
        &self.artifact_key
    }
}

impl Failed {
    /// Creates a failed job.
    pub fn new(id: impl Into<String>, reason: impl Into<String>) -> Self {
        Self { id: id.into(), reason: reason.into() }
    }

    /// The job id.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Why the job failed.
    pub fn reason(&self) -> &str {
        &self.reason
    }
}

impl ExportJob {
    /// The job id, whatever the state.
    pub fn id(&self) -> &str {
        match self {
            Self::Queued(job) => job.id(),
            Self::Running(job) => job.id(),
            Self::Ready(job) => job.id(),
            Self::Failed(job) => job.id(),
        }
    }
}

/// Why a running job could not complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompleteError {
    /// The artifact key was empty or whitespace.
    BlankArtifactKey,
}

impl fmt::Display for CompleteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BlankArtifactKey => f.write_str("export completion requires an artifact key"),
        }
    }
}

impl std::error::Error for CompleteError {}

/// Moves a queued job to running.
pub fn start(job: Queued) -> Running {
    Running { id: job.id }
}

/// Moves a running job to ready. The artifact key must not be blank.
pub fn complete(job: Running, artifact_key: &str) -> Result<Ready, CompleteError> {
    if artifact_key.trim().is_empty() {
        return Err(CompleteError::BlankArtifactKey);
    }
    Ok(Ready { id: job.id, artifact_key: artifact_key.to_owned() })
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn completes_running_job_with_artifact_key() {
        let ready = complete(start(Queued::new("job-1")), "exports/job-1.csv").unwrap();
        assert_eq!(ready.id(), "job-1");
        assert_eq!(ready.artifact_key(), "exports/job-1.csv");
    }

    #[test]
    fn rejects_blank_artifact_key() {
        assert_eq!(complete(start(Queued::new("job-1")), "  "), Err(CompleteError::BlankArtifactKey));
    }

    proptest! {
        /// Property: for any id and any non-blank key, completing keeps both.
        #[test]
        fn keeps_id_and_key_for_any_non_blank_key(id in ".*", key in ".*\\S.*") {
            let ready = complete(start(Queued::new(id.clone())), &key).unwrap();
            prop_assert_eq!(ready.id(), id.as_str());
            prop_assert_eq!(ready.artifact_key(), key.as_str());
        }
    }
}
