#!/usr/bin/env python3
"""Run the WeRead sync-status Home module in real KOReader and SimpleUI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import zipfile

from mock_weread import MockServer


REPO = Path(__file__).resolve().parent.parent
SPEC = REPO / "spec/koreader/weread_simpleui_status.lua"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def plugin_version(archive: Path) -> str:
    with zipfile.ZipFile(archive) as package:
        metadata = package.read("weread.koplugin/_meta.lua").decode()
    for line in metadata.splitlines():
        if "version" in line and '"' in line:
            return line.split('"', 2)[1]
    raise RuntimeError("candidate package has no version")


def simpleui_version(archive: Path) -> str:
    with zipfile.ZipFile(archive) as package:
        metadata = package.read("simpleui.koplugin/_meta.lua").decode()
    for line in metadata.splitlines():
        if "version" in line and '"' in line:
            return line.split('"', 2)[1]
    raise RuntimeError("SimpleUI package has no version")


def write_profile(profile: Path, port: int) -> None:
    settings = profile / "settings/simpleui"
    settings.mkdir(parents=True)
    (profile / "weread-mock/cache").mkdir(parents=True)
    (profile.parent / "evidence").mkdir(parents=True, exist_ok=True)
    (profile / "settings.reader.lua").write_text(
        'return { language = "zh_CN", color_rendering = false, '
        'auto_save_settings_interval_minutes = 0, flash_ui = false }\n'
    )
    (profile / "settings/weread-environment.lua").write_text(
        f'return {{ enabled = true, host = "127.0.0.1", port = {port} }}\n'
    )
    (profile / "settings/weread-mock.lua").write_text(
        '''return {
    account = { login_method = "mock", name = "Mock", user_vid = "900000" },
    api_key = "mock-api-key",
    auth_schema_version = 1,
    cookies = { wr_skey = "mock-only", wr_vid = "900000" },
    books = {},
    cache = { auto_prefetch_next_chapter = false, show_prefetch_notifications = false,
        show_annotations = true, prefetch_annotations = false },
    read_report = { enabled = true, mode = "auto", interval_seconds = 10,
        report_on_open = true },
    sync = { upload_annotations = true, upload_on_close = true,
        ask_on_conflict = true, heartbeat_minutes = 10 },
    update = { auto_check = false, repository = "lonelygo/weread.koplugin" },
    wr_ticket = "", wr_wrpa = "",
}
'''
    )
    (settings / "sui_settings.lua").write_text(
        '''return {
    simpleui_enabled = true,
    simpleui_onboarding_done = true,
    simpleui_updater_auto_check = false,
    simpleui_start_with_homescreen = false,
    simpleui_layout = { pages = {
        { id = 1, modules = { "clock", "quote", "currently" } },
        { id = 2, modules = { "recent" } },
    } },
    simpleui_hs_module_order = {
        "clock", "quote", "currently", "__page_break__", "recent",
    },
    simpleui_hs_clock_enabled = true,
    simpleui_hs_clock_date = false,
    simpleui_hs_clock_battery = false,
    simpleui_hs_quote_enabled = true,
    simpleui_hs_currently_enabled = true,
    simpleui_hs_recent_enabled = true,
    simpleui_hs_recent_exclude_currently = true,
    simpleui_hs_currently_show_title = true,
    simpleui_hs_currently_show_author = true,
    simpleui_hs_currently_show_progress = true,
}
'''
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True,
                        help="KOReader runtime directory containing luajit")
    parser.add_argument("--simpleui-zip", type=Path, required=True,
                        help="official SimpleUI 3.1.0 release ZIP")
    parser.add_argument("--candidate-zip", type=Path,
                        help="reuse an existing candidate ZIP instead of packaging the workspace")
    parser.add_argument("--run-dir", type=Path,
                        help="new evidence directory; a temporary directory is used when omitted")
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    args = parser.parse_args()

    if args.width < 320 or args.height < 480 or args.dpi < 80:
        parser.error("screen dimensions or DPI are outside the supported test range")

    runtime = args.koreader.resolve()
    simpleui_zip = args.simpleui_zip.resolve()
    if not (runtime / "luajit").is_file():
        parser.error("--koreader must contain the KOReader luajit executable")
    if not simpleui_zip.is_file():
        parser.error("--simpleui-zip does not exist")
    version = simpleui_version(simpleui_zip)
    if version != "3.1.0":
        parser.error(f"expected SimpleUI 3.1.0, got {version}")

    run_dir = (args.run_dir.resolve() if args.run_dir else
               Path(tempfile.mkdtemp(prefix="weread-simpleui-status-")))
    if args.run_dir:
        run_dir.mkdir(parents=True, exist_ok=False)
    profile = run_dir / "profile"
    plugins = profile / "plugins"
    plugins.mkdir(parents=True)
    evidence = run_dir / "evidence"
    evidence.mkdir()
    candidate = (args.candidate_zip.resolve() if args.candidate_zip
                 else run_dir / "weread-candidate.zip")
    if args.candidate_zip:
        if not candidate.is_file():
            parser.error("--candidate-zip does not exist")
    else:
        subprocess.run(["bash", str(REPO / "scripts/package_release.sh"), str(candidate)],
                       cwd=REPO, check=True, stdout=subprocess.PIPE, text=True)
    with zipfile.ZipFile(candidate) as package:
        package.extractall(plugins)
    with zipfile.ZipFile(simpleui_zip) as package:
        package.extractall(plugins)

    server = MockServer(0, evidence / "requests.jsonl", "127.0.0.1")
    write_profile(profile, server.server_port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = os.environ | {
        "KO_HOME": str(profile),
        "EMULATE_READER_W": str(args.width),
        "EMULATE_READER_H": str(args.height),
        "EMULATE_READER_DPI": str(args.dpi),
        "KO_DYLD_PREFIX": str(runtime),
        "SDL_VIDEODRIVER": "offscreen",
        "SDL_AUDIODRIVER": "dummy",
    }
    build = {
        "plugin_version": plugin_version(candidate),
        "simpleui_version": version,
        "runtime": str(runtime),
        "candidate": str(candidate),
        "candidate_sha256": sha256(candidate),
        "simpleui_sha256": sha256(simpleui_zip),
        "screen": {"width": args.width, "height": args.height, "dpi": args.dpi},
        "workspace_status": subprocess.check_output(
            ["git", "status", "--short"], cwd=REPO, text=True),
    }
    (evidence / "build.json").write_text(
        json.dumps(build, ensure_ascii=False, indent=2) + "\n"
    )
    log = evidence / "runtime.log"
    result = None
    try:
        with log.open("w") as output:
            result = subprocess.run(
                ["./luajit", str(SPEC)], cwd=runtime, env=environment,
                stdout=output, stderr=subprocess.STDOUT, timeout=180,
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        with server.lock:
            state = {
                "progress": server.progress,
                "read_reports": server.read_reports,
                "annotation_writes": server.annotation_writes,
            }
        (evidence / "server-state.json").write_text(
            json.dumps(state, ensure_ascii=False, indent=2) + "\n"
        )

    if result is None or result.returncode != 0:
        print(f"FAIL: {log}")
        raise SystemExit(1 if result is None else result.returncode)
    durations = [report["rt"] for report in state["read_reports"]
                 if report["bookId"] == "900001" and report["rt"] > 0]
    notes = [write["payload"] for write in state["annotation_writes"] if write["path"] == "/web/review/add"]
    received = sorted((note["bookId"], note["content"], note["isPrivate"]) for note in notes)
    if durations != [30, 20, 7] or received != [("900001", "私密笔记1", 1), ("900001", "私密笔记2", 1)]:
        raise RuntimeError("Manual sync did not deliver the exact time slices and two private notes")
    screenshots = sorted(evidence.glob("*.png"))
    if len(screenshots) != 9:
        raise RuntimeError(f"expected 9 screenshots, found {len(screenshots)}")
    for screenshot in screenshots:
        data = screenshot.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError(f"not a PNG: {screenshot}")
        dimensions = struct.unpack(">II", data[16:24])
        if dimensions != (args.width, args.height):
            raise RuntimeError(
                f"wrong screenshot dimensions for {screenshot}: {dimensions}"
            )
    print(f"PASS: {log}")
    print(f"Evidence: {evidence}")


if __name__ == "__main__":
    main()
