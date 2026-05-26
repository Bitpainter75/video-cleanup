#!/usr/bin/env python3
"""
watchdog_processor.py
Überwacht /input auf neue Videodateien und startet video_cleanup.sh pro Datei.
"""

import os
import sys
import time
import subprocess
import logging
from datetime import datetime
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# ── Konfiguration aus Umgebungsvariablen ──────────────────────────────────────
INPUT_DIR    = os.environ.get("INPUT_DIR",    "/input")
OUTPUT_DIR   = os.environ.get("OUTPUT_DIR",   "/output")
LOG_FILE     = os.environ.get("LOG_FILE",     "/logs/video-cleanup.log")
SCRIPT_PATH  = os.environ.get("SCRIPT_PATH",  "/app/video_cleanup.sh")
EXTENSIONS   = set(
    os.environ.get("EXTENSIONS", "mkv mp4 avi ts m2ts mov").split()
)
# Sekunden warten, bis Datei stabil (fertig kopiert) ist
STABLE_SECS  = int(os.environ.get("STABLE_SECS", "30"))

# ── Logging ───────────────────────────────────────────────────────────────────
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

fmt = "%(asctime)s [%(levelname)s] %(message)s"
datefmt = "%Y-%m-%d %H:%M:%S"

handlers = [
    logging.StreamHandler(sys.stdout),
    logging.FileHandler(LOG_FILE, encoding="utf-8"),
]
logging.basicConfig(level=logging.INFO, format=fmt, datefmt=datefmt, handlers=handlers)
log = logging.getLogger("watchdog")


def is_video(path: str) -> bool:
    return Path(path).suffix.lstrip(".").lower() in EXTENSIONS


def wait_for_stable(path: str, stable_secs: int = STABLE_SECS) -> bool:
    """Wartet bis sich die Dateigröße STABLE_SECS lang nicht mehr ändert."""
    prev_size = -1
    stable_count = 0
    for _ in range(300):          # max. 300 Versuche × 1s = 5 min Timeout
        try:
            size = os.path.getsize(path)
        except OSError:
            return False
        if size == prev_size:
            stable_count += 1
            if stable_count >= stable_secs:
                return True
        else:
            stable_count = 0
        prev_size = size
        time.sleep(1)
    log.warning("Timeout: Datei ist nach 5 min noch nicht stabil: %s", path)
    return False


def process_file(filepath: str) -> None:
    log.info("━" * 55)
    log.info("Neue Datei erkannt: %s", filepath)

    if not wait_for_stable(filepath):
        log.error("Datei übersprungen (nicht stabil): %s", filepath)
        return

    env = {**os.environ, "OUTPUT_DIR": OUTPUT_DIR, "LOG_FILE": LOG_FILE}
    cmd = ["bash", SCRIPT_PATH, filepath]

    log.info("Starte Verarbeitung: %s", " ".join(cmd))
    try:
        result = subprocess.run(
            cmd,
            env=env,
            capture_output=False,   # stdout/stderr gehen direkt ins Terminal
            text=True,
        )
        if result.returncode == 0:
            log.info("✔ Erfolgreich verarbeitet: %s", filepath)
        else:
            log.error("✘ Fehler (exit %d): %s", result.returncode, filepath)
    except Exception as exc:
        log.exception("Unerwarteter Fehler bei %s: %s", filepath, exc)


class VideoHandler(FileSystemEventHandler):
    def on_created(self, event):
        if event.is_directory:
            return
        if is_video(event.src_path):
            process_file(event.src_path)

    def on_moved(self, event):
        """Fängt auch atomare Moves ab (z.B. von rsync/mv)."""
        if event.is_directory:
            return
        if is_video(event.dest_path):
            process_file(event.dest_path)


def scan_existing() -> None:
    """Verarbeitet bereits vorhandene Dateien beim Start."""
    found = []
    for root, _, files in os.walk(INPUT_DIR):
        for fname in sorted(files):
            if is_video(fname):
                found.append(os.path.join(root, fname))
    if found:
        log.info("Vorhandene Dateien beim Start gefunden: %d", len(found))
        for fp in found:
            process_file(fp)
    else:
        log.info("Keine vorhandenen Dateien im Input-Ordner.")


def main() -> None:
    log.info("═" * 55)
    log.info("  Video Cleanup Watchdog gestartet")
    log.info("  Input  : %s", INPUT_DIR)
    log.info("  Output : %s", OUTPUT_DIR)
    log.info("  Log    : %s", LOG_FILE)
    log.info("  Skript : %s", SCRIPT_PATH)
    log.info("  Formate: %s", ", ".join(sorted(EXTENSIONS)))
    log.info("═" * 55)

    os.makedirs(INPUT_DIR,  exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    scan_existing()

    observer = Observer()
    observer.schedule(VideoHandler(), INPUT_DIR, recursive=True)
    observer.start()
    log.info("Watchdog aktiv – warte auf neue Dateien in: %s", INPUT_DIR)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log.info("Watchdog wird beendet...")
        observer.stop()
    observer.join()
    log.info("Watchdog beendet.")


if __name__ == "__main__":
    main()
