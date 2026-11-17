class InMemoryArtifactStore:
    def __init__(self) -> None:
        self._files: dict[str, str] = {}

    def save(self, job_id: str, content: str) -> str:
        key = f"exports/{job_id}.csv"
        self._files[key] = content
        return key

    def read(self, key: str) -> str | None:
        return self._files.get(key)
