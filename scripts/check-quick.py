#!/usr/bin/env python3
"""Run independent local checks concurrently, with explicit scopes and timings.

This is fast feedback, not the release gate: CI still runs race tests, Rust,
Swift CodecKit, production builds and packaged-server/proxy smoke checks.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def check_stages(schema_python):
    return {
        "web": [(["bun", "run", "check"], ROOT), (["bun", "test", "src/lib"], ROOT)],
        "server": [(["go", "vet", "./..."], ROOT / "sync-server"),
                   (["go", "test", "./..."], ROOT / "sync-server")],
        "contracts": [([schema_python, "scripts/test-import-schema.py"], ROOT),
                      ([sys.executable, "scripts/test-server-release.py"], ROOT),
                      ([sys.executable, "-m", "unittest", "discover", "-s", "deploy/ubuntu", "-p", "test_*.py"], ROOT)],
    }


def run_stage(name, commands, output_directory):
    started = time.monotonic()
    log_path = output_directory / f"{name}.log"
    status = 0
    with log_path.open("w") as log:
        for command, directory in commands:
            log.write("$ " + shlex.join(command) + "\n")
            log.flush()
            try:
                status = subprocess.run(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT).returncode
            except OSError as error:
                log.write(f"Could not run {command[0]}: {error}\n")
                status = 127
            if status != 0:
                break
    return {"scope": name, "exit_code": status, "seconds": round(time.monotonic() - started, 3), "log": str(log_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", action="append", choices=("web", "server", "contracts"),
                        help="Run only these scopes; repeat to combine. Default: all three")
    parser.add_argument("--serial", action="store_true", help="Run scopes sequentially for diagnostics")
    parser.add_argument("--report-dir", type=Path, help="Save private logs/timings here (default: new temporary directory)")
    parser.add_argument("--list", action="store_true", help="Show selected checks without running anything")
    args = parser.parse_args()
    cached_python = Path.home() / ".cache/codec-checks/bin/python3"
    schema_python = os.environ.get("CODEC_SCHEMA_PYTHON") or (str(cached_python) if cached_python.is_file() else sys.executable)
    stages = check_stages(schema_python)
    selected = list(dict.fromkeys(args.scope or stages))
    if args.list:
        for name in selected:
            for command, _ in stages[name]:
                print(f"{name}: {shlex.join(command)}")
        return 0
    if "contracts" in selected:
        try:
            ready = subprocess.run([schema_python, "-c", "import jsonschema, referencing"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        except OSError:
            ready = False
        if not ready:
            parser.error("Schema dependencies are missing. Run: python3 -m venv ~/.cache/codec-checks && "
                         "~/.cache/codec-checks/bin/python3 -m pip install jsonschema==4.26.0; "
                         "or set CODEC_SCHEMA_PYTHON to an existing schema-test environment.")
    output = args.report_dir.resolve() if args.report_dir else Path(tempfile.mkdtemp(prefix="codec-check-quick-"))
    output.mkdir(parents=True, exist_ok=True)
    output.chmod(0o700)
    started = time.monotonic()
    results = []
    with ThreadPoolExecutor(max_workers=1 if args.serial else len(selected)) as workers:
        pending = {workers.submit(run_stage, name, stages[name], output): name for name in selected}
        for completed in as_completed(pending):
            result = completed.result()
            results.append(result)
            print(f"{'PASS' if result['exit_code'] == 0 else 'FAIL'} {result['scope']}: {result['seconds']:.2f}s", flush=True)
            if result["exit_code"]:
                print("\n".join(Path(result["log"]).read_text().splitlines()[-30:]), flush=True)
    elapsed = round(time.monotonic() - started, 3)
    report = {"schema": "codec.quick-check.v1", "parallel": not args.serial,
              "wall_seconds": elapsed, "checks": sorted(results, key=lambda value: value["scope"])}
    (output / "timings.json").write_text(json.dumps(report, indent=2) + "\n")
    passed = all(result["exit_code"] == 0 for result in results)
    print(f"{'Passed' if passed else 'Failed'} in {elapsed:.2f}s. Logs and timings: {output}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
