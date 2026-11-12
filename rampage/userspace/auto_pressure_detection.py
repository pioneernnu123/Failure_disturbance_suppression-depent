#!/usr/bin/env python3
"""Check available memory, then run the session-owned acceptance workflow."""

import argparse
from pathlib import Path
import subprocess
import sys
import time

import psutil


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", type=int, default=None)
    parser.add_argument("--pages", type=int, default=8)
    parser.add_argument("--inject-page", type=int, default=5)
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--case", choices=["all", "3-3-0006", "3-3-0007",
                                          "3-3-0008", "3-3-0009"], default="all")
    args = parser.parse_args(argv)
    memory = psutil.virtual_memory()
    available_mb = memory.available / (1024 * 1024)
    print(f"memory used={memory.percent:.1f}% available={available_mb:.0f} MiB")
    if memory.percent > 85 or available_mb < 1024:
        print("Not enough free memory for the test page pool.", file=sys.stderr)
        return 1
    run_id = args.run_id if args.run_id is not None else time.time_ns() & ((1 << 63) - 1)
    command = [sys.executable, str(Path(__file__).with_name("run_memory_test.py")),
               "--run-id", str(run_id), "--pages", str(args.pages),
               "--inject-page", str(args.inject_page), "--case", args.case]
    output_dir = args.output_dir or str(
        Path.home() / "failure-disturbance-runs" / str(run_id))
    command += ["--output-dir", output_dir]
    print(f"RUN_ID={run_id}", flush=True)
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
