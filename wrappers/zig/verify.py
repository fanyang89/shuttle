"""Exercise aborting Rust/Zig scenarios as child processes, including replay."""

import re
import resource
import subprocess
import sys

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run(*args):
    return subprocess.run(
        [sys.argv[1], *args], capture_output=True, text=True, timeout=15
    )


stdgo = sys.argv[2:] == ["stdgo"]
passing = (
    ("basic", "pool", "semaphore", "errgroup", "clients", "pipe", "db")
    if stdgo
    else ("locked", "atomics")
)
for name in passing:
    result = run(name)
    assert result.returncode == 0, result.stderr

failures = (
    (
        ("singleflight", "IncorrectShared"),
        ("canceled", "AcquiredAfterCancellation"),
        ("group-oom", "exceeded max_steps"),
        ("flight-oom", "LockHeldAfterAllocationFailure"),
        ("group-deinit", "exceeded max_steps"),
    )
    if stdgo
    else (
        ("lost-update", "LostUpdate"),
        ("spin", "exceeded max_steps"),
        ("deadlock", "deadlock! blocked tasks"),
    )
)
for name, reason in failures:
    result = run(name)
    assert result.returncode != 0 and reason in result.stderr, result.stderr
    trace = re.search(r'failing schedule:\n"\n([0-9a-f\s]+)\n"', result.stderr)
    assert trace, result.stderr
    replay = run(name, trace[1])
    assert replay.returncode != 0 and reason in replay.stderr, replay.stderr
    if stdgo:
        print(f"{name}: {reason}; replay OK: {trace[1]}")
