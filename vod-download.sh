#!/usr/bin/env bash
#
# vod-download.sh — download the latest full-length video from a YouTube playlist.
#
# Source: any newest-first YouTube playlist that may also hold shorter cuts and
# clips. A duration gate keeps only entries longer than $MIN_DURATION, so the
# script grabs the latest *full* video and ignores the short ones.
#
#   * A yt-dlp download archive ensures a video grabbed earlier is never re-downloaded.
#   * After each run only the newest $KEEP_LATEST videos are kept (disk is limited);
#     the archive file is preserved, so rotated-out videos are still never re-fetched.
#
# An OPTIONAL accept-window (WINDOW_START/WINDOW_END) can restrict downloads to a
# video published within a recent time range — useful for a daily broadcast that
# you only want to fetch the morning after. Leave both empty to disable it and
# simply take the newest video over the duration gate.
#
set -euo pipefail

# --- config -----------------------------------------------------------------
# All tunables live in vod-scraper.conf (looked up via $VOD_CONFIG, then next to
# this script, then /etc/vod-scraper.conf). The defaults below are the fallback,
# so the script still runs if no config file is present.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PLAYLIST=""              # REQUIRED: the YouTube playlist URL to track. Set in config.
DEST="/home/dietpi/media_store"
ARCHIVE=""               # empty -> defaults to $DEST/downloaded.txt after config load
MIN_DURATION=5400        # seconds; 1 h 30 m. Keep only entries longer than this.
SCAN_DEPTH=50            # how many newest playlist entries to scan for a full video.
KEEP_LATEST=7            # number of most-recent videos to keep on disk.
WINDOW_START=""          # optional accept-window bounds; empty = window disabled.
WINDOW_END=""            # see the note below for the semantics when both are set.
MERGE_FORMAT="mp4"
EXTRACT_AUDIO=true       # also write a lossless .m4a sidecar (AAC copy, iOS-native).
COOKIES=""               # optional yt-dlp cookies file; empty = none (public playlist).
YTDLP="${YTDLP:-yt-dlp}"
TZ_NAME="UTC"            # all dates/times are evaluated in this timezone.

for _cfg in "${VOD_CONFIG:-}" "$SCRIPT_DIR/vod-scraper.conf" "/etc/vod-scraper.conf"; do
    if [[ -n "$_cfg" && -f "$_cfg" ]]; then
        # shellcheck source=/dev/null
        source "$_cfg"
        echo "Loaded config: $_cfg"
        break
    fi
done

if [[ -z "$PLAYLIST" ]]; then
    echo "vod-download: PLAYLIST is not set. Set it in vod-scraper.conf (see vod-scraper.conf.example)." >&2
    exit 1
fi

: "${ARCHIVE:=$DEST/downloaded.txt}"
COOKIE_ARGS=()
[[ -n "$COOKIES" ]] && COOKIE_ARGS=( --cookies "$COOKIES" )

# Optional accept window. When both WINDOW_START and WINDOW_END are set, a video
# only counts as "fresh" if its publish time falls in
# [yesterday $WINDOW_START, today $WINDOW_END] (evaluated in $TZ_NAME). This suits
# a daily broadcast you fetch the morning after: WINDOW_START sits a little before
# the broadcast usually ends, WINDOW_END tolerates an upload that finishes the next
# day. Leave either empty to disable the check and just take the newest full video.
WINDOW_ENABLED=false
[[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] && WINDOW_ENABLED=true

# Evaluate every date/time in the configured timezone, regardless of the box clock.
export TZ="$TZ_NAME"
# ----------------------------------------------------------------------------

mkdir -p "$DEST"

# 1) Locate the latest full video. Flat extraction is a single cheap request and
#    exposes each entry's duration; newest-first ordering means the first entry
#    with a real duration over the threshold is the most recent full video.
#    Upcoming/live entries carry no duration and are skipped by the numeric test.
listing="$("$YTDLP" "${COOKIE_ARGS[@]}" --flat-playlist --no-warnings --playlist-end "$SCAN_DEPTH" \
            --print "%(duration)s %(id)s" "$PLAYLIST")"

latest_id="$(awk -v min="$MIN_DURATION" \
    '$1 ~ /^[0-9]+$/ && $1+0 > min { print $2; exit }' <<< "$listing")"

if [[ -z "$latest_id" ]]; then
    echo "No full video (> ${MIN_DURATION}s) found in the newest ${SCAN_DEPTH} entries."
    exit 0
fi

echo "Latest full video: https://youtu.be/${latest_id}"

# 2) Read the publish timestamp (yt-dlp "timestamp"; for a live VOD this is ~the
#    end of the broadcast). Used to stamp a date into the filename, and — when the
#    accept window is enabled — to decide whether this is a fresh-enough video.
ts="$("$YTDLP" "${COOKIE_ARGS[@]}" --skip-download --no-warnings \
        --print "%(timestamp)s" "https://www.youtube.com/watch?v=${latest_id}")"

if [[ "$ts" =~ ^[0-9]+$ ]]; then
    # Map the publish time to its "broadcast day". When the window is enabled we use
    # WINDOW_START as the day boundary (a next-day upload belongs to the prior day);
    # otherwise the stamped date is simply the publish date in $TZ_NAME.
    pub_date="$(date -d "@$ts" +%F)"
    if [[ "$WINDOW_ENABLED" == "true" ]] && (( ts >= $(date -d "$pub_date $WINDOW_START" +%s) )); then
        stamp_date="$pub_date"
    elif [[ "$WINDOW_ENABLED" == "true" ]]; then
        stamp_date="$(date -d "$pub_date -1 day" +%F)"
    else
        stamp_date="$pub_date"
    fi
    echo "Published $(date -d "@$ts" +'%a %F %H:%M %Z') -> stamped date $(date -d "$stamp_date" +'%A %F')"
else
    if [[ "$WINDOW_ENABLED" == "true" ]]; then
        echo "No usable publish timestamp for ${latest_id} (got '${ts}'); skipping."
        exit 0
    fi
    echo "No usable publish timestamp for ${latest_id} (got '${ts}'); stamping today's date."
    stamp_date="$(date +%F)"
fi

# 2b) Enforce the accept window (only when enabled).
if [[ "$WINDOW_ENABLED" == "true" ]]; then
    win_lo="$(date -d "yesterday $WINDOW_START" +%s)"
    win_hi="$(date -d "today $WINDOW_END" +%s)"
    if (( ts < win_lo || ts >= win_hi )); then
        echo "Outside accept window [$(date -d "@$win_lo" +'%a %F %H:%M') .. $(date -d "@$win_hi" +'%a %F %H:%M')); nothing fresh this run, skipping."
        exit 0
    fi
fi

# 3) Download it. --download-archive records completed downloads, so a video
#    already fetched on a previous run is skipped and yt-dlp exits cleanly.
#    Prefer mp4/m4a (H.264/AAC) and merge to .mp4; optionally also extract an .m4a.
dl_args=(
    "${COOKIE_ARGS[@]}"
    --download-archive "$ARCHIVE"
    --no-progress
    --no-overwrites
    -S "vcodec:h264,ext:mp4:m4a"
    --merge-output-format "$MERGE_FORMAT"
    # Name by the stamped date (computed above), so the catalog sorts by date.
    --output "$DEST/${stamp_date} - %(title)s [%(id)s].%(ext)s"
)
if [[ "$EXTRACT_AUDIO" == "true" ]]; then
    # Keep the video AND write a separate .m4a — copies the AAC track (no re-encode).
    dl_args+=( --extract-audio --keep-video --audio-format m4a )
fi
"$YTDLP" "${dl_args[@]}" "https://www.youtube.com/watch?v=${latest_id}"

# --keep-video also leaves the pre-merge stream fragments ("<name>.f137.mp4",
# "<name>.f140.m4a", ...). Remove them so only the final .mp4 (+ .m4a) remain;
# matched by regex (not a glob) so the "[id]" in filenames is taken literally.
if [[ "$EXTRACT_AUDIO" == "true" ]]; then
    find "$DEST" -maxdepth 1 -type f -regextype posix-extended \
        -regex '.*\.f[0-9]+\.[^.]+$' -delete
fi

# 4) Rotate: keep only the newest $KEEP_LATEST videos. We track the .mp4 files (one
#    per video), newest-first by mtime, and remove everything past the keep window
#    together with each video's sidecar .m4a (deleted by exact path, never a glob).
mapfile -t vids < <(
    find "$DEST" -maxdepth 1 -type f -name '*.mp4' -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2-
)
for old in "${vids[@]:KEEP_LATEST}"; do
    echo "Rotating out: $old"
    rm -f -- "$old" "${old%.mp4}.m4a"
done
