"""The open-loop HTTP load generator.

*Open loop* means requests are started on a schedule (``rate`` per second), whether or not the
earlier ones have finished: a slow server does not slow the clients down, it builds a queue, as
real phones would. A closed loop (N workers, each waiting for its answer) hides exactly the
latency this measures. Latency is taken from the **scheduled** start, so that a generator that
fell behind cannot flatter the server (coordinated omission); the raw time on the wire is kept
as well.
"""

from __future__ import annotations

import asyncio
import math
import time
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

import httpx


@dataclass(frozen=True)
class Sample:
    scheduled_at: float  # seconds since the start of the run
    latency_ms: float  # from the scheduled start
    wire_ms: float  # from the moment the request was sent
    status: int  # 0 = transport error
    replayed: bool
    body: Any = None


def percentile(values: Sequence[float], q: float) -> float:
    """Linear-interpolated percentile of ``values`` (``q`` in 0..100)."""
    if not values:
        return math.nan
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (q / 100) * (len(ordered) - 1)
    low = math.floor(rank)
    high = math.ceil(rank)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


@dataclass
class Summary:
    count: int
    ok: int
    errors: int
    error_rate: float
    statuses: dict[int, int]
    p50: float
    p95: float
    p99: float
    max: float
    mean: float
    wire_p95: float
    achieved_rps: float
    duration_s: float
    replayed: int = 0

    def as_dict(self) -> dict[str, Any]:
        return {
            "count": self.count,
            "ok": self.ok,
            "errors": self.errors,
            "error_rate": round(self.error_rate, 5),
            "statuses": {str(k): v for k, v in sorted(self.statuses.items())},
            "latency_ms": {
                "p50": round(self.p50, 1),
                "p95": round(self.p95, 1),
                "p99": round(self.p99, 1),
                "max": round(self.max, 1),
                "mean": round(self.mean, 1),
                "wire_p95": round(self.wire_p95, 1),
            },
            "achieved_rps": round(self.achieved_rps, 1),
            "duration_s": round(self.duration_s, 1),
            "replayed": self.replayed,
        }


def summarise(samples: Sequence[Sample], *, ok_status: int = 200, duration: float) -> Summary:
    latencies = [s.latency_ms for s in samples]
    statuses = Counter(s.status for s in samples)
    ok = statuses.get(ok_status, 0)
    return Summary(
        count=len(samples),
        ok=ok,
        errors=len(samples) - ok,
        error_rate=(len(samples) - ok) / len(samples) if samples else math.nan,
        statuses=dict(statuses),
        p50=percentile(latencies, 50),
        p95=percentile(latencies, 95),
        p99=percentile(latencies, 99),
        max=max(latencies) if latencies else math.nan,
        mean=sum(latencies) / len(latencies) if latencies else math.nan,
        wire_p95=percentile([s.wire_ms for s in samples], 95),
        achieved_rps=len(samples) / duration if duration > 0 else math.nan,
        duration_s=duration,
        replayed=sum(1 for s in samples if s.replayed),
    )


@dataclass
class RunResult:
    samples: list[Sample] = field(default_factory=list)
    duration: float = 0.0
    late_starts: int = 0  # requests the generator itself started more than 50 ms late


def make_client(base_url: str, *, connections: int = 256) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=base_url,
        timeout=httpx.Timeout(30.0, connect=10.0),
        limits=httpx.Limits(max_connections=connections, max_keepalive_connections=connections),
    )


Request = Callable[[int], tuple[str, str, dict[str, str], Any]]
"""``i`` -> (method, path, headers, json body or None)"""


async def open_loop(
    client: httpx.AsyncClient,
    request: Request,
    *,
    rate: float,
    duration: float,
    keep_body: Callable[[int], bool] | None = None,
) -> RunResult:
    """Send ``rate`` requests per second for ``duration`` seconds, then wait for the stragglers."""
    total = int(rate * duration)
    result = RunResult()
    started = time.perf_counter()
    tasks: list[asyncio.Task[None]] = []

    async def one(i: int, scheduled: float) -> None:
        method, path, headers, body = request(i)
        sent = time.perf_counter()
        status, replayed, payload = 0, False, None
        try:
            response = await client.request(method, path, headers=headers, json=body)
            status = response.status_code
            replayed = response.headers.get("idempotent-replayed") == "true"
            if keep_body is not None and keep_body(i):
                payload = response.json() if response.content else None
        except httpx.HTTPError:
            status = 0
        end = time.perf_counter()
        result.samples.append(
            Sample(
                scheduled_at=scheduled,
                latency_ms=(end - started - scheduled) * 1000,
                wire_ms=(end - sent) * 1000,
                status=status,
                replayed=replayed,
                body=payload,
            )
        )

    for i in range(total):
        scheduled = i / rate
        delay = scheduled - (time.perf_counter() - started)
        if delay > 0:
            await asyncio.sleep(delay)
        elif -delay > 0.05:  # noqa: PLR2004
            result.late_starts += 1
        tasks.append(asyncio.create_task(one(i, scheduled)))
    await asyncio.gather(*tasks)
    result.duration = time.perf_counter() - started
    return result
