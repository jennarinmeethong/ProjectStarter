"""Illegal states are unrepresentable: only a running job can complete,
and a ready job always has an artifact key."""

from dataclasses import dataclass


@dataclass(frozen=True)
class QueuedExport:
    id: str


@dataclass(frozen=True)
class RunningExport:
    id: str


@dataclass(frozen=True)
class ReadyExport:
    id: str
    artifact_key: str


@dataclass(frozen=True)
class FailedExport:
    id: str
    reason: str


type ExportJob = QueuedExport | RunningExport | ReadyExport | FailedExport


def start_export(job: QueuedExport) -> RunningExport:
    return RunningExport(id=job.id)


def complete_export(job: RunningExport, artifact_key: str) -> ReadyExport:
    if not artifact_key.strip():
        raise ValueError("Export completion requires an artifact key")
    return ReadyExport(id=job.id, artifact_key=artifact_key)
