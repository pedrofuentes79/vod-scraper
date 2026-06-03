#!/usr/bin/env bash
#
# vod-ingest.sh — register downloaded videos in the media-server SQLite DB.
#
# Standalone & idempotent reconciler: scans $DEST for *.mp4 (+ its matching .m4a
# sidecar) and INSERTs a row for any file not already in the database. Safe to
# run anytime — manually, or via vod-ingest.service after a download. Files that
# are already registered are skipped, so re-runs are no-ops.
#
# Deliberately knows nothing about downloading: the downloader fetches files,
# this reconciles the directory against the DB. Config (DEST, DB_PATH) is loaded
# from vod-scraper.conf, exactly like vod-download.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# defaults (overridden by config)
DEST="/home/dietpi/media_store"
DB_PATH="/home/dietpi/media-server/media.db"

for _cfg in "${VOD_CONFIG:-}" "$SCRIPT_DIR/vod-scraper.conf" "/etc/vod-scraper.conf"; do
    if [[ -n "$_cfg" && -f "$_cfg" ]]; then
        # shellcheck source=/dev/null
        source "$_cfg"
        break
    fi
done

command -v sqlite3 >/dev/null || { echo "vod-ingest: sqlite3 not found" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "vod-ingest: ffprobe not found (install ffmpeg)" >&2; exit 1; }

if [[ ! -f "$DB_PATH" ]]; then
    echo "vod-ingest: DB not found at $DB_PATH" >&2
    echo "  Start the media server once so it runs migrations and creates the DB." >&2
    exit 1
fi

# Normalize so stored realpaths share a common prefix with DEST (for pruning).
DEST="$(realpath -m -- "$DEST")"

# Double up single quotes -> safe SQL string literal.
esc() { local s="$1"; printf '%s' "${s//\'/\'\'}"; }

added=0
shopt -s nullglob
for video in "$DEST"/*.mp4; do
    video="$(realpath -- "$video")"
    stem="$(basename -- "$video")"; stem="${stem%.mp4}"

    audio="$DEST/${stem}.m4a"
    if [[ -f "$audio" ]]; then audio="$(realpath -- "$audio")"; else audio=""; fi

    # Already registered (by either path)? -> skip.
    if [[ -n "$(sqlite3 "$DB_PATH" \
        "SELECT 1 FROM media WHERE video_path='$(esc "$video")' \
            OR (audio_path<>'' AND audio_path='$(esc "$audio")') LIMIT 1;")" ]]; then
        continue
    fi

    # Derive date + title from the "YYYY-MM-DD - Title [id]" filename
    # (also accepts a legacy "YYYYMMDD - Title [id]" stem).
    date_raw="${stem%% - *}"
    rest="${stem#* - }"
    title="${rest% \[*}"           # strip trailing " [id]"
    if [[ "$date_raw" =~ ^[0-9]{8}$ ]]; then
        date="${date_raw:0:4}-${date_raw:4:2}-${date_raw:6:2}"
    else
        date="$date_raw"
    fi

    # Duration (s) from the audio sidecar if present, else the video.
    probe="${audio:-$video}"
    dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$probe" 2>/dev/null || true)"
    dur="${dur%.*}"               # drop fractional part
    [[ "$dur" =~ ^[0-9]+$ ]] && (( dur > 0 )) || dur=7200

    sqlite3 "$DB_PATH" \
        "INSERT INTO media (date, title, video_path, audio_path, progress_seconds, total_seconds)
         VALUES ('$(esc "$date")', '$(esc "$title")', '$(esc "$video")', '$(esc "$audio")', 0, $dur);"
    echo "registered: $title  (${dur}s)"
    added=$((added + 1))
done

# Prune: drop rows for files WE manage (under $DEST) that no longer exist on disk
# — e.g. videos the downloader rotated out. Path matching is done in bash so there's
# no LIKE/GLOB escaping to worry about; rows outside $DEST are never touched.
pruned=0
while IFS=$'\t' read -r id vpath; do
    [[ -n "$id" ]] || continue
    [[ "$vpath" == "$DEST/"* ]] || continue
    [[ -f "$vpath" ]] && continue
    sqlite3 "$DB_PATH" "DELETE FROM media WHERE id=$id;"
    echo "pruned: $vpath"
    pruned=$((pruned + 1))
done < <(sqlite3 -separator $'\t' "$DB_PATH" "SELECT id, video_path FROM media;")

echo "vod-ingest: $added new video(s) registered, $pruned stale row(s) pruned in $DB_PATH"
