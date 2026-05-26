#!/bin/bash
# ============================================================
# video_cleanup.sh  –  Docker-Version
# Verarbeitet eine einzelne Datei, schreibt Output in OUTPUT_DIR
# Alle Parameter kommen als Umgebungsvariablen rein.
# ============================================================

set -uo pipefail

# --- ffmpeg/ffprobe ---
FFMPEG="${FFMPEG_BIN:-ffmpeg}"
FFPROBE="${FFPROBE_BIN:-ffprobe}"

# --- Env-Variablen mit Defaults ---
KEEP_LANGS="${KEEP_LANGS:-deu ger de}"           # Sprachen behalten (space-separated)
CLEANUP="${CLEANUP:-true}"                        # Nicht-gewünschte Spuren entfernen
REMOVE_ALL_SUBS="${REMOVE_ALL_SUBS:-false}"       # Alle Untertitel entfernen
REMOVE_METADATA="${REMOVE_METADATA:-false}"       # Metadaten entfernen
NORMALIZE="${NORMALIZE:-false}"                   # loudnorm 2-Pass aktivieren
KEEP_BACKUP="${KEEP_BACKUP:-false}"               # Backup im Input-Ordner behalten
EXTENSIONS="${EXTENSIONS:-mkv mp4 avi ts m2ts mov}"

# Ziel-Datei wird als erstes Argument übergeben (durch den Watchdog)
INPUT_FILE="$1"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
LOG_FILE="${LOG_FILE:-/logs/video-cleanup.log}"

# --- Farben (werden in Log entfernt) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Logging mit Zeitstempel ---
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # Farbcodes aus Log-Datei entfernen
    local clean_msg
    clean_msg="$(echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g')"
    echo -e "${ts} [${level}] ${msg}"
    echo "${ts} [${level}] ${clean_msg}" >> "$LOG_FILE"
}

# --- Temp-Datei-Tracking für sauberen Abbruch ---
CURRENT_TMPFILE=""
interrupted=false

cleanup_on_exit() {
    if [[ "$interrupted" == true ]]; then
        log "WARN" "⚠ Abgebrochen! Unvollständige Temp-Datei wird gelöscht."
        if [[ -n "$CURRENT_TMPFILE" && -f "$CURRENT_TMPFILE" ]]; then
            rm -f "$CURRENT_TMPFILE"
            log "INFO" "Gelöscht: $CURRENT_TMPFILE"
        fi
    fi
}

handle_interrupt() {
    interrupted=true
    kill "$(jobs -p)" 2>/dev/null || true
    exit 130
}

trap cleanup_on_exit EXIT
trap handle_interrupt INT TERM

# --- Voraussetzungen ---
if ! command -v "$FFMPEG" &>/dev/null && [[ ! -x "$FFMPEG" ]]; then
    log "ERROR" "ffmpeg nicht gefunden: $FFMPEG"
    exit 1
fi
if ! command -v "$FFPROBE" &>/dev/null && [[ ! -x "$FFPROBE" ]]; then
    log "ERROR" "ffprobe nicht gefunden: $FFPROBE"
    exit 1
fi

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
    log "ERROR" "Keine gültige Eingabedatei: '${INPUT_FILE:-}'"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# --- Streams auslesen ---
get_streams() {
    local file="$1"
    "$FFPROBE" -v quiet \
        -show_entries stream=index,codec_type:stream_tags=language \
        -of default=noprint_wrappers=1 \
        "$file" 2>/dev/null \
    | awk '
        BEGIN { idx=""; ctype=""; lang="" }
        /^index=/ {
            if (ctype != "") {
                if (lang == "") lang="und"
                print idx "|" ctype "|" lang
                lang=""
            }
            idx=substr($0,7); ctype=""
        }
        /^codec_type=/   { ctype=substr($0,12) }
        /^TAG:language=/ { lang=substr($0,14) }
        /^\[\/STREAM\]/  { if (lang == "") lang="und"; print idx "|" ctype "|" lang; idx=""; ctype=""; lang="" }
        END {
            if (ctype != "") {
                if (lang == "") lang="und"
                print idx "|" ctype "|" lang
            }
        }
    '
}

# --- Ist Sprache auf der Behalten-Liste? ---
is_keep_lang() {
    local lang="${1,,}"
    local k
    for k in $KEEP_LANGS; do
        [[ "$lang" == "${k,,}" ]] && return 0
    done
    return 1
}

# --- Ist Datei bereits normalisiert? ---
is_normalized() {
    local file="$1"
    local tag
    tag=$("$FFPROBE" -v quiet \
        -show_entries stream_tags=normalized \
        -select_streams a:0 \
        -of default=noprint_wrappers=1 \
        "$file" 2>/dev/null | grep -c "TAG:normalized=true" || true)
    [[ $tag -gt 0 ]] && return 0 || return 1
}

# --- Spur-Info loggen ---
show_stream_info() {
    local streams="$1"
    local audio_count="$2"
    while IFS='|' read -r idx ctype lang; do
        [[ -z "$ctype" ]] && continue
        if [[ "$ctype" == "audio" ]]; then
            if is_keep_lang "$lang"; then
                log "INFO" "  Audio  #${idx}: lang=${lang}  ${GREEN}✔ behalten${RESET}"
            elif [[ $audio_count -eq 1 ]]; then
                log "INFO" "  Audio  #${idx}: lang=${lang}  ${YELLOW}✔ behalten (einzige Spur)${RESET}"
            else
                log "INFO" "  Audio  #${idx}: lang=${lang}  ${RED}✘ entfernen${RESET}"
            fi
        elif [[ "$ctype" == "subtitle" ]]; then
            if [[ "$REMOVE_ALL_SUBS" == "true" ]]; then
                log "INFO" "  Sub    #${idx}: lang=${lang}  ${RED}✘ entfernen (alle Subs weg)${RESET}"
            elif is_keep_lang "$lang"; then
                log "INFO" "  Sub    #${idx}: lang=${lang}  ${GREEN}✔ behalten${RESET}"
            else
                log "INFO" "  Sub    #${idx}: lang=${lang}  ${RED}✘ entfernen${RESET}"
            fi
        fi
    done <<< "$streams"
}

# --- Datei bereinigen → Output-Ordner ---
cleanup_file() {
    local file="$1"
    local base ext name outfile tmpfile
    base="$(basename "$file")"
    ext="${base##*.}"
    name="${base%.*}"
    outfile="${OUTPUT_DIR}/${base}"
    tmpfile="${OUTPUT_DIR}/.tmp_clean_${name}.${ext}"

    local streams
    streams=$(get_streams "$file")

    local ff_args=(-nostdin -i "$file" -map 0:v:0 -c:v copy)
    local audio_count=0 kept_audio=0 s_kept=0

    while IFS='|' read -r _ ctype _; do
        [[ "$ctype" == "audio" ]] && audio_count=$((audio_count+1))
    done <<< "$streams"

    while IFS='|' read -r idx ctype lang; do
        [[ -z "$ctype" ]] && continue
        if [[ "$ctype" == "audio" ]]; then
            if is_keep_lang "$lang" || [[ $audio_count -eq 1 ]]; then
                ff_args+=(-map "0:$idx")
                kept_audio=$((kept_audio+1))
            fi
        fi
    done <<< "$streams"

    [[ $kept_audio -gt 0 ]] && ff_args+=(-c:a copy)

    if [[ "$REMOVE_ALL_SUBS" != "true" ]]; then
        while IFS='|' read -r idx ctype lang; do
            [[ "$ctype" != "subtitle" ]] && continue
            if is_keep_lang "$lang"; then
                ff_args+=(-map "0:$idx")
                s_kept=$((s_kept+1))
            fi
        done <<< "$streams"
        [[ $s_kept -gt 0 ]] && ff_args+=(-c:s copy)
    fi

    ff_args+=(-map_chapters 0)

    if [[ "$REMOVE_METADATA" == "true" ]]; then
        ff_args+=(-map_metadata -1)
    else
        ff_args+=(-map_metadata 0)
    fi

    ff_args+=("$tmpfile")

    CURRENT_TMPFILE="$tmpfile"
    log "INFO" "  → ffmpeg: ${ff_args[*]}"

    if "$FFMPEG" -threads 0 "${ff_args[@]}" -loglevel error -stats 2>&1 | \
        while IFS= read -r line; do log "INFO" "    $line"; done; then
        mv "$tmpfile" "$outfile"
        CURRENT_TMPFILE=""
        # Original aus Input entfernen – verarbeitete Version liegt in Output
        rm -f "$file"
        log "INFO" "${GREEN}✔ Bereinigt → ${outfile}${RESET}"
    else
        rm -f "$tmpfile"
        CURRENT_TMPFILE=""
        log "ERROR" "${RED}✘ Fehler bei der Bereinigung von: ${file}${RESET}"
        return 1
    fi
}

# --- Audio normalisieren → Output-Ordner ---
normalize_file() {
    local file="$1"
    local base ext name outfile tmpfile
    base="$(basename "$file")"
    ext="${base##*.}"
    name="${base%.*}"
    outfile="${OUTPUT_DIR}/${base}"
    tmpfile="${OUTPUT_DIR}/.tmp_norm_${name}.${ext}"

    # Falls Datei schon im Output liegt (nach cleanup), von dort normalisieren
    if [[ -f "$outfile" ]]; then
        file="$outfile"
        tmpfile="${OUTPUT_DIR}/.tmp_norm2_${name}.${ext}"
    fi

    if is_normalized "$file"; then
        log "INFO" "${GREEN}✔ Bereits normalisiert – übersprungen${RESET}"
        return 0
    fi

    log "INFO" "  ${CYAN}Pass 1: Lautstärke-Analyse...${RESET}"

    local loudnorm_out
    loudnorm_out=$("$FFMPEG" -nostdin -i "$file" \
        -af "loudnorm=I=-23:TP=-1.5:LRA=11:print_format=json" \
        -f null /dev/null 2>&1 | grep -A 20 "^\{" || true)

    if [[ -z "$loudnorm_out" ]]; then
        log "ERROR" "${RED}✘ Pass 1 fehlgeschlagen${RESET}"
        return 1
    fi

    local il itp lra thresh offset
    il=$(echo "$loudnorm_out"     | grep '"input_i"'       | grep -o '[-0-9.]*' | head -1)
    itp=$(echo "$loudnorm_out"    | grep '"input_tp"'      | grep -o '[-0-9.]*' | head -1)
    lra=$(echo "$loudnorm_out"    | grep '"input_lra"'     | grep -o '[-0-9.]*' | head -1)
    thresh=$(echo "$loudnorm_out" | grep '"input_thresh"'  | grep -o '[-0-9.]*' | head -1)
    offset=$(echo "$loudnorm_out" | grep '"target_offset"' | grep -o '[-0-9.]*' | head -1)

    log "INFO" "  ${CYAN}Pass 2: Normalisiere (I=${il} LUFS → -23 LUFS)...${RESET}"

    CURRENT_TMPFILE="$tmpfile"
    if "$FFMPEG" -nostdin -threads 0 -i "$file" \
        -map 0:v -c:v copy \
        -map 0:a:0 \
        -af "loudnorm=I=-23:TP=-1.5:LRA=11:linear=true:measured_I=${il}:measured_TP=${itp}:measured_LRA=${lra}:measured_thresh=${thresh}:offset=${offset}:print_format=summary" \
        -ac 2 -c:a aac -b:a 192k \
        -metadata:s:a:0 normalized=true \
        -map_chapters 0 -map_metadata 0 -sn \
        -loglevel error -stats \
        "$tmpfile" 2>&1 | while IFS= read -r line; do log "INFO" "    $line"; done; then
        mv "$tmpfile" "$outfile"
        CURRENT_TMPFILE=""
        # Original aus Input entfernen, falls cleanup es nicht bereits getan hat
        [[ -f "$INPUT_FILE" ]] && rm -f "$INPUT_FILE"
        log "INFO" "${GREEN}✔ Normalisiert → ${outfile}${RESET}"
    else
        rm -f "$tmpfile"
        CURRENT_TMPFILE=""
        log "ERROR" "${RED}✘ Fehler bei der Normalisierung${RESET}"
        return 1
    fi
}

# ============================================================
# MAIN
# ============================================================
file="$INPUT_FILE"
base="$(basename "$file")"
outfile="${OUTPUT_DIR}/${base}"

log "INFO" "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
log "INFO" "Verarbeite: ${BOLD}${file}${RESET}"
log "INFO" "  Behalte Sprachen : ${KEEP_LANGS}"
log "INFO" "  Bereinigen       : ${CLEANUP}"
log "INFO" "  Alle Subs weg    : ${REMOVE_ALL_SUBS}"
log "INFO" "  Metadaten weg    : ${REMOVE_METADATA}"
log "INFO" "  Normalisieren    : ${NORMALIZE}"

streams=$(get_streams "$file")
AUDIO_COUNT=0
SUB_COUNT=0

while IFS='|' read -r _ ctype _; do
    [[ "$ctype" == "audio" ]]    && AUDIO_COUNT=$((AUDIO_COUNT+1))
    [[ "$ctype" == "subtitle" ]] && SUB_COUNT=$((SUB_COUNT+1))
done <<< "$streams"

HAS_META=0
if [[ "$REMOVE_METADATA" == "true" ]]; then
    HAS_META=$("$FFPROBE" -v quiet -show_entries format_tags \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null \
        | grep "^TAG:" \
        | grep -iv "TAG:major_brand\|TAG:minor_version\|TAG:compatible_brands\|TAG:encoder\|TAG:handler_name\|TAG:vendor_id\|TAG:software\|TAG:creation_time\|TAG:language" \
        | grep -c "^TAG:" || true)
fi

log "INFO" "  Audio-Spuren: ${AUDIO_COUNT} | Untertitel: ${SUB_COUNT} | Metadaten: ${HAS_META}"
show_stream_info "$streams" "$AUDIO_COUNT"

NEEDS_PROCESS=false
[[ "$CLEANUP" == "true" && ( $AUDIO_COUNT -gt 1 || $SUB_COUNT -gt 0 || $HAS_META -gt 0 ) ]] && NEEDS_PROCESS=true
[[ "$NORMALIZE" == "true" ]] && NEEDS_PROCESS=true

if [[ "$NEEDS_PROCESS" == "false" ]]; then
    log "INFO" "${YELLOW}Keine Verarbeitung notwendig – verschiebe Datei direkt.${RESET}"
    mv "$file" "$outfile"
    log "INFO" "${GREEN}✔ Verschoben → ${outfile}${RESET}"
    exit 0
fi

if [[ "$CLEANUP" == "true" && ( $AUDIO_COUNT -gt 1 || $SUB_COUNT -gt 0 || $HAS_META -gt 0 ) ]]; then
    log "INFO" "${CYAN}→ Starte Bereinigung...${RESET}"
    cleanup_file "$file"
fi

if [[ "$NORMALIZE" == "true" ]]; then
    log "INFO" "${CYAN}→ Starte Normalisierung...${RESET}"
    normalize_file "$file"
fi

log "INFO" "${GREEN}${BOLD}✔ Fertig: ${base}${RESET}"
log "INFO" "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
