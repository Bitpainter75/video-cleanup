# ============================================================
# Dockerfile – Video Cleanup Watchdog
# ============================================================
FROM python:3.12-slim

LABEL maintainer="video-cleanup"
LABEL description="Watchdog-basierter Video-Cleaner mit ffmpeg"

# ── System-Pakete ─────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        bash \
    && rm -rf /var/lib/apt/lists/*

# ── Python-Abhängigkeiten ─────────────────────────────────
RUN pip install --no-cache-dir watchdog==4.0.1

# ── App-Dateien ───────────────────────────────────────────
WORKDIR /app
COPY video_cleanup.sh  /app/video_cleanup.sh
COPY watchdog_processor.py /app/watchdog_processor.py
RUN chmod +x /app/video_cleanup.sh

# ── Verzeichnisse anlegen ─────────────────────────────────
RUN mkdir -p /input /output /logs

# ── Umgebungsvariablen / Defaults ────────────────────────
#   Sprache(n) behalten – komma- ODER leerzeichen-getrennt
ENV KEEP_LANGS="deu ger de"
#   Verarbeitungs-Optionen
ENV CLEANUP="true"
ENV REMOVE_ALL_SUBS="false"
ENV REMOVE_METADATA="false"
ENV NORMALIZE="false"
ENV KEEP_BACKUP="false"
#   Dateierweiterungen (leerzeichen-getrennt)
ENV EXTENSIONS="mkv mp4 avi ts m2ts mov"
#   Pfade
ENV INPUT_DIR="/input"
ENV OUTPUT_DIR="/output"
ENV LOG_FILE="/logs/video-cleanup.log"
ENV SCRIPT_PATH="/app/video_cleanup.sh"
#   ffmpeg-Binaries (Standard: System-ffmpeg)
ENV FFMPEG_BIN="ffmpeg"
ENV FFPROBE_BIN="ffprobe"
#   Sekunden, bis eine neue Datei als "fertig kopiert" gilt
ENV STABLE_SECS="5"

# ── Volumes ───────────────────────────────────────────────
VOLUME ["/input", "/output", "/logs"]

# ── Einstiegspunkt ────────────────────────────────────────
CMD ["python3", "-u", "/app/watchdog_processor.py"]
