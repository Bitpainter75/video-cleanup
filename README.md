# Video Cleanup – Docker Watchdog

A Docker container that watches an input folder for new video files and automatically processes them using ffmpeg — stripping unwanted audio/subtitle tracks, removing metadata, and optionally normalizing audio. Processed files are written to an output folder; all actions are logged with timestamps.

## Quick Start

```bash
# 1. Create local folders
mkdir -p input output logs

# 2. Build and start
docker compose up -d --build

# 3. Drop a video in — processing starts automatically
cp my_movie.mkv input/

# 4. Follow the log
tail -f logs/video-cleanup.log
```

## How It Works

1. A **Python watchdog** monitors `/input` for new or moved video files
2. Waits until the file size has been stable for `STABLE_SECS` seconds (safe for slow network copies)
3. Calls `video_cleanup.sh` with the file as argument
4. The script writes the result to `/output` — the original in `/input` is never touched (unless `KEEP_BACKUP=false`, in which case it is removed after successful processing)
5. Every action is appended with a timestamp to `/logs/video-cleanup.log`

## Directory Structure

```
.
├── Dockerfile
├── docker-compose.yml
├── README.md
├── video_cleanup.sh        # ffmpeg processing logic
└── watchdog_processor.py  # folder watcher
    
# runtime:
├── input/    ← drop videos here
├── output/   ← processed files appear here
└── logs/
    └── video-cleanup.log
```

## Environment Variables

| Variable          | Default            | Description                                                   |
|-------------------|--------------------|---------------------------------------------------------------|
| `KEEP_LANGS`      | `deu ger de`       | Language codes to keep (space-separated)                      |
| `CLEANUP`         | `true`             | Remove audio/subtitle tracks not in `KEEP_LANGS`              |
| `REMOVE_ALL_SUBS` | `false`            | Strip all subtitle tracks (including kept languages)          |
| `REMOVE_METADATA` | `false`            | Remove all metadata/tags from the container                   |
| `NORMALIZE`       | `false`            | loudnorm 2-pass audio normalization (→ AAC 192k stereo)       |
| `KEEP_BACKUP`     | `false`            | Keep original as `.bak` in the input folder                   |
| `EXTENSIONS`      | `mkv mp4 avi ts m2ts mov` | Space-separated list of monitored file extensions    |

## Changing the Language

Edit `KEEP_LANGS` in `docker-compose.yml`:

```yaml
# English only
KEEP_LANGS: "eng en"

# German + English
KEEP_LANGS: "deu ger de eng en"

# Japanese only
KEEP_LANGS: "jpn ja"
```

## Example Configurations

### Clean tracks only (keep German)
```yaml
CLEANUP: "true"
KEEP_LANGS: "deu ger de"
REMOVE_ALL_SUBS: "false"
REMOVE_METADATA: "false"
NORMALIZE: "false"
```

### Full cleanup + normalize (English)
```yaml
CLEANUP: "true"
KEEP_LANGS: "eng en"
REMOVE_ALL_SUBS: "true"
REMOVE_METADATA: "true"
NORMALIZE: "true"
```

## Log Format

```
2025-03-15 14:23:01 [INFO] New file detected: /input/movie.mkv
2025-03-15 14:23:06 [INFO] Processing: /input/movie.mkv
2025-03-15 14:23:06 [INFO]   Keep languages : deu ger de
2025-03-15 14:23:06 [INFO]   Audio tracks: 3 | Subtitles: 2
2025-03-15 14:23:06 [INFO]   Audio  #1: lang=deu  ✔ keep
2025-03-15 14:23:06 [INFO]   Audio  #2: lang=eng  ✘ remove
2025-03-15 14:23:06 [INFO]   Audio  #3: lang=und  ✘ remove
2025-03-15 14:23:06 [INFO]   → Starting cleanup...
2025-03-15 14:23:44 [INFO]   ✔ Cleaned → /output/movie.mkv
2025-03-15 14:23:45 [INFO] ✔ Successfully processed: /input/movie.mkv
```

## Requirements

- Docker Engine 24+ with Compose v2
- The container ships with `ffmpeg` from the Debian package repos.
