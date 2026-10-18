"""Check panic containment versus process abort in disposable BEAM processes."""
import os
from pathlib import Path
import resource
import signal
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ENV = dict(os.environ, MIX_ENV="test", PARLORA_ISOLATED_FAULT_PROBE="1")


def disable_core_dumps():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


for case, marker in [
    ("panic", "PANIC_CAUGHT_BEAM_AND_CODEC_ALIVE"),
    ("resource_panic", "POISONED_STATE_REJECTED_AND_RELEASED"),
    ("abort", "ABOUT_TO_ABORT_DISPOSABLE_BEAM"),
]:
    child = subprocess.Popen(
        ["mix", "run", "--no-compile", "scripts/fault_probe.exs", case],
        cwd=ROOT, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, start_new_session=True, preexec_fn=disable_core_dumps,
    )
    try:
        output, _ = child.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate()
        raise AssertionError(f"{case} timed out: {output}")
    assert marker in output, (case, child.returncode, output)
    if case == "abort":
        assert child.returncode in (-signal.SIGABRT, 128 + signal.SIGABRT), output
        assert "UNEXPECTED_ABORT_RETURN" not in output
    else:
        assert child.returncode == 0, output
    print(f"{case}: PASS (child exit {child.returncode}; {marker})", flush=True)
