"""Versioned collection contracts and fixed resource budgets."""
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass(frozen=True)
class Identity:
    pid: int
    starttime_ticks: int
    exe: str
    cgroup: str
    exe_device: int = 0
    exe_inode: int = 0


@dataclass(frozen=True)
class Budget:
    deadline_seconds: float
    perf_seconds: int = 10
    perf_hz: int = 19
    max_text_bytes: int = 2 * 1024 * 1024
    max_perf_bytes: int = 16 * 1024 * 1024
    max_bundle_bytes: int = 24 * 1024 * 1024
    read_bytes: int = 65536
    max_pids: int = 1024
    max_workers: int = 64
    child_as_bytes: int = 256 * 1024 * 1024
    rss_stop_bytes: int = 96 * 1024 * 1024
    budget_version: int = 1


@dataclass
class Result:
    name: str
    status: str
    reason: Optional[str] = None
    data: Dict[str, Any] = field(default_factory=dict)
    evidence: List[str] = field(default_factory=list)
