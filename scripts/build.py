#!/usr/bin/env python3
"""Implement a routed same-clock context, or diagnose bare OOC ports."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def windows_path(path):
    if os.name == "nt":
        return str(path)
    return subprocess.check_output(["wslpath", "-w", str(path)], text=True).strip()


def validate_result(output):
    result = output / "result.txt"
    if not result.is_file():
        raise SystemExit("Vivado did not produce result.txt")
    if "Implementation status: PASS" not in result.read_text(encoding="utf-8").splitlines():
        raise SystemExit(f"Implementation did not pass all timing/coverage/DRC gates; inspect {result}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("top", nargs="?", default="stream_arbiter",
                        choices=["stream_arbiter", "stream_selftest"])
    parser.add_argument("--context", default="registered", choices=["registered", "ports"],
                        help="registered: physical same-clock boundary; ports: original abstract I/O diagnostic")
    args = parser.parse_args()
    executable = os.environ.get("VIVADO") or shutil.which("vivado") or shutil.which("vivado.bat")
    if not executable:
        for path in (Path("/mnt/e/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"),
                     Path("E:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat")):
            if path.is_file():
                executable = str(path)
                break
    if not executable:
        raise SystemExit("Set VIVADO to vivado or vivado.bat, or put it on PATH")
    script = ROOT / "scripts" / "vivado.tcl"
    output = ROOT / "build" / "vivado" / args.top / args.context
    output.mkdir(parents=True, exist_ok=True)
    if Path(executable).suffix.lower() in (".bat", ".cmd"):
        # Invoke a generated batch file by its plain name. Embedding quotes in
        # cmd.exe arguments is unreliable across WSL's Windows argument bridge.
        exe = windows_path(executable) if str(executable).startswith("/") else executable
        arguments = [exe, "-mode", "batch", "-notrace", "-source", windows_path(script),
                     "-tclargs", args.top, args.context]
        if any(any(c in arg for c in '\r\n"') for arg in arguments):
            raise SystemExit("Invalid quote or newline in Vivado/script path")
        quoted = " ".join('"' + arg.replace("%", "%%") + '"' for arg in arguments)
        (output / "launch.cmd").write_text("@echo off\n" + quoted + "\n", encoding="utf-8")
        cmd = shutil.which("cmd.exe")
        if not cmd:
            raise SystemExit("Windows Vivado launcher requires cmd.exe on PATH")
        command = [cmd, "/d", "/v:off", "/c", "launch.cmd"]
    else:
        command = [executable, "-mode", "batch", "-notrace", "-source", str(script),
                   "-tclargs", args.top, args.context]
    # A previous build must never masquerade as this invocation's result.
    (output / "result.txt").unlink(missing_ok=True)
    print(f"Implementing {args.top} ({args.context}); reports: {output}", flush=True)
    with (output / "launcher.log").open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=output, text=True, encoding="utf-8", errors="replace",
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in process.stdout:
            log.write(line)
            log.flush()
            print(line, end="", flush=True)
        status = process.wait()
    if status:
        raise SystemExit(f"Vivado exited {status}; inspect {output / 'result.txt'} and launcher.log")
    # Some Windows batch launchers return zero even when Tcl raised an error.
    validate_result(output)


if __name__ == "__main__":
    main()
