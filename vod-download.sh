#!/usr/bin/env bash
#
# vod-download.sh — download the AUDIO of every new long video from the tracked
# YouTube sources.
#
# Source: one or more newest-first YouTube listings ($SOURCES) — channel tabs
# (".../videos", ".../streams") or playlists. Each may also hold shorts, clips
# and cuts, so a duration gate keeps only entries longer than $MIN_DURATION.
# Everything over the gate is wanted, not just the newest one: each run picks up
# every long video that isn't already in the download archive.
#
# Audio only: the catalog is a listening app, so we fetch the audio stream and
# write a single .m4a per video. No video is ever downloaded.
#
#   * A yt-dlp download archive ensures a video grabbed earlier is never re-downloaded.
#   * After each run only the newest $KEEP_LATEST recordings are kept (disk is limited);
#     the archive file is preserved, so rotated-out videos are still never re-fetched.
#   * At most $MAX_NEW downloads happen per run, so a first run against a fresh
#     channel can't spend all night fetching a backlog it would only rotate away.
#
set -euo pipefail

# --- config -----------------------------------------------------------------
# All tunables live in vod-scraper.conf (looked up via $VOD_CONFIG, then next to
# this script, then /etc/vod-scraper.conf). The defaults below are the fallback,
# so the script still runs if no config file is present.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SOURCES=()        # REQUIRED: bash array of listing URLs to track. Set in config.
PLAYLIST=""       # legacy single-URL alias for SOURCES; still honoured if set.
DEST="/home/dietpi/media_store"
ARCHIVE=""        # empty -> defaults to $DEST/downloaded.txt after config load
MIN_DURATION=3600 # seconds; 1 h. Keep only entries longer than this.
SCAN_DEPTH=50     # how many newest entries to scan per source.
KEEP_LATEST=7     # number of most-recent recordings to keep on disk.
MAX_NEW=0         # max downloads per run; 0 -> $KEEP_LATEST.
AUDIO_FORMAT="m4a" # output audio container (m4a = lossless copy of YouTube's AAC).
COOKIES=""        # optional yt-dlp cookies file; empty = none (public source).
YTDLP_ARGS=()     # extra yt-dlp flags applied to every call (see the config example).
YTDLP="${YTDLP:-yt-dlp}"
TZ_NAME="UTC"     # all dates/times are evaluated in this timezone.

for _cfg in "${VOD_CONFIG:-}" "$SCRIPT_DIR/vod-scraper.conf" "/etc/vod-scraper.conf"; do
  if [[ -n "$_cfg" && -f "$_cfg" ]]; then
    # shellcheck source=/dev/null
    source "$_cfg"
    echo "Loaded config: $_cfg"
    break
  fi
done

# A config predating $SOURCES only sets $PLAYLIST — treat it as a one-entry list.
if ((${#SOURCES[@]} == 0)) && [[ -n "$PLAYLIST" ]]; then
  SOURCES=("$PLAYLIST")
fi
if ((${#SOURCES[@]} == 0)); then
  echo "vod-download: SOURCES is not set. Set it in vod-scraper.conf (see vod-scraper.conf.example)." >&2
  exit 1
fi

: "${ARCHIVE:=$DEST/downloaded.txt}"
((MAX_NEW > 0)) || MAX_NEW="$KEEP_LATEST"
COOKIE_ARGS=()
[[ -n "$COOKIES" ]] && COOKIE_ARGS=(--cookies "$COOKIES")
# Every yt-dlp invocation gets these, so a listing, a metadata read and a download
# all see the same channel the same way.
COMMON_ARGS=("${COOKIE_ARGS[@]}" "${YTDLP_ARGS[@]}")

# Evaluate every date/time in the configured timezone, regardless of the box clock.
export TZ="$TZ_NAME"
# ----------------------------------------------------------------------------

mkdir -p "$DEST"

# Already fetched on an earlier run? yt-dlp archive lines are "<extractor> <id>".
in_archive() {
  [[ -f "$ARCHIVE" ]] && awk -v id="$1" '$NF == id { found = 1 } END { exit !found }' "$ARCHIVE"
}

# 1) Candidates. Flat extraction is a single cheap request per source and exposes
#    each entry's duration; newest-first ordering means the first $KEEP_LATEST
#    entries over the gate are the newest long videos that source has. Upcoming
#    and live entries carry no duration and are skipped by the numeric test.
candidates=()
for src in "${SOURCES[@]}"; do
  echo "Scanning: $src"
  if ! listing="$("$YTDLP" "${COMMON_ARGS[@]}" --flat-playlist --no-warnings \
    --playlist-end "$SCAN_DEPTH" --print "%(duration)s %(id)s" "$src" 2>&1)"; then
    echo "  could not read this source; skipping it this run." >&2
    continue
  fi
  # yt-dlp prints the duration as an integer on new builds and a float ("2749.0")
  # on older ones — accept both. Upcoming/live entries print "NA" and are excluded.
  mapfile -t hits < <(awk -v min="$MIN_DURATION" -v keep="$KEEP_LATEST" \
    '$1 ~ /^[0-9]+(\.[0-9]+)?$/ && $1+0 > min { print $2; if (++n == keep) exit }' <<<"$listing")
  echo "  ${#hits[@]} video(s) over ${MIN_DURATION}s in the newest ${SCAN_DEPTH} entries"
  candidates+=("${hits[@]}")
done

# 2) Drop duplicates (a video can sit in more than one source) and anything the
#    archive already knows about — that's either on disk or deliberately rotated out.
declare -A seen=()
fresh=()
for id in "${candidates[@]}"; do
  [[ -n "${seen[$id]:-}" ]] && continue
  seen[$id]=1
  in_archive "$id" && continue
  fresh+=("$id")
done

if ((${#fresh[@]} == 0)); then
  echo "Nothing new over ${MIN_DURATION}s across ${#SOURCES[@]} source(s)."
else
  # 3) Read each candidate's publish timestamp (for a live VOD this is ~the end of
  #    the broadcast). It both stamps the date into the filename and puts the
  #    candidates in true chronological order — the flat listings are per-source,
  #    so concatenating them says nothing about how they interleave.
  urls=()
  for id in "${fresh[@]}"; do urls+=("https://www.youtube.com/watch?v=$id"); done
  meta_err="$(mktemp)"
  mapfile -t meta < <("$YTDLP" "${COMMON_ARGS[@]}" --skip-download --no-warnings \
    --ignore-errors --print "%(timestamp,release_timestamp)s %(id)s" "${urls[@]}" 2>"$meta_err" || true)

  # Candidates yt-dlp could not read are named, never silently dropped — the usual
  # cause is a members-only upload, which only $COOKIES can unlock, and a run that
  # quietly downloaded nothing would look identical to "there was nothing new".
  declare -A got=()
  for line in "${meta[@]}"; do got["${line##* }"]=1; done
  unreachable=0
  for id in "${fresh[@]}"; do
    [[ -n "${got[$id]:-}" ]] && continue
    reason="$(grep -m1 -F -- "$id" "$meta_err" | sed 's/^ERROR: *//' | cut -c1-200 || true)"
    echo "  unavailable: ${id} — ${reason:-yt-dlp returned no metadata}" >&2
    unreachable=$((unreachable + 1))
  done
  rm -f "$meta_err"

  # Newest first, cut to $MAX_NEW, then flip to oldest-first: downloading in publish
  # order keeps mtime order (which rotation below uses) matching broadcast order.
  now="$(date +%s)"
  mapfile -t queue < <(
    for line in "${meta[@]}"; do
      ts="${line%% *}"
      id="${line##* }"
      [[ "$ts" =~ ^[0-9]+$ ]] || ts="$now" # no usable timestamp -> treat as "just now"
      printf '%s %s\n' "$ts" "$id"
    done | sort -rn | head -n "$MAX_NEW" | sort -n
  )

  # Only fetch what will still be here after rotation. Merge the publish dates
  # already on disk with the candidates' dates, keep the newest $KEEP_LATEST, and
  # treat the oldest of those as the cutoff. Without this, a channel tab whose tail
  # reaches back years has the run download those old entries over a slow link just
  # to delete them again minutes later in step 5.
  mapfile -t have_dates < <(
    find "$DEST" -maxdepth 1 -type f -name "*.${AUDIO_FORMAT}" -printf '%f\n' | cut -d' ' -f1
  )
  cutoff="$(
    {
      ((${#have_dates[@]} > 0)) && printf '%s\n' "${have_dates[@]}"
      for entry in "${queue[@]}"; do date -d "@${entry%% *}" +%F; done
    } | sed '/^$/d' | sort -r | head -n "$KEEP_LATEST" | tail -1
  )"

  deferred=$((${#meta[@]} - ${#queue[@]}))
  echo "${#fresh[@]} new video(s) over the gate; ${unreachable} unavailable, downloading ${#queue[@]} this run."
  ((deferred > 0)) && echo "  ${deferred} older one(s) deferred by MAX_NEW=${MAX_NEW}; a later run will pick them up."

  # 4) Download the audio. --download-archive records completed downloads, so a
  #    video already fetched on a previous run is skipped and yt-dlp exits cleanly.
  #    bestaudio[ext=m4a] is YouTube's AAC track, so writing .m4a is a container
  #    copy (no re-encode, near-instant on a Pi, and iOS-native).
  dl_args=(
    "${COMMON_ARGS[@]}"
    --download-archive "$ARCHIVE"
    --no-progress
    --no-overwrites
    -f "bestaudio[ext=${AUDIO_FORMAT}]/bestaudio"
    --extract-audio
    --audio-format "$AUDIO_FORMAT"
    # Write the metadata sidecar ("<stem>.info.json") next to the audio. The ingest
    # reads its ".chapters" (YouTube chapter markers) into the DB so the player can
    # offer chapter navigation. NOT --split-chapters: the file stays whole.
    --write-info-json
  )

  ok=0
  bad=0
  skipped=0
  for entry in "${queue[@]}"; do
    ts="${entry%% *}"
    id="${entry##* }"
    stamp_date="$(date -d "@$ts" +%F)"
    if [[ -n "$cutoff" && "$stamp_date" < "$cutoff" ]]; then
      echo "Skipping https://youtu.be/${id} (${stamp_date}) — older than the newest ${KEEP_LATEST}; rotation would delete it immediately."
      skipped=$((skipped + 1))
      continue
    fi
    echo "Downloading https://youtu.be/${id} — published $(date -d "@$ts" +'%a %F %H:%M %Z'), stamped ${stamp_date}"
    # Name by the publish date, so the catalog sorts by date.
    if "$YTDLP" "${dl_args[@]}" \
      --output "$DEST/${stamp_date} - %(title)s [%(id)s].%(ext)s" \
      "https://www.youtube.com/watch?v=${id}"; then
      ok=$((ok + 1))
    else
      echo "  download failed for ${id}; continuing with the rest." >&2
      bad=$((bad + 1))
    fi
  done
  echo "${ok} downloaded, ${bad} failed, ${skipped} skipped as too old to keep."
fi

# 5) Rotate: keep only the newest $KEEP_LATEST recordings, ordered by the PUBLISH
#    date each filename starts with ("YYYY-MM-DD - …"), so a plain reverse sort is
#    newest-broadcast-first. Deliberately NOT mtime: a backfill run downloads old
#    episodes today, giving them the newest mtime, and an mtime sort would then
#    evict recent episodes to keep years-old ones.
#    Each dropped file's .info.json goes with it — as does a legacy .mp4 from back
#    when this script also downloaded video (by exact path, never a glob).
mapfile -t auds < <(
  find "$DEST" -maxdepth 1 -type f -name "*.${AUDIO_FORMAT}" | sort -r
)
for old in "${auds[@]:KEEP_LATEST}"; do
  echo "Rotating out: $old"
  rm -f -- "$old" "${old%.$AUDIO_FORMAT}.info.json" "${old%.$AUDIO_FORMAT}.mp4"
done

# Downloads were attempted and every one of them failed -> report the run as failed
# (a partial success still counts, so the ingest that follows on success can run).
if ((${bad:-0} > 0 && ${ok:-0} == 0)); then
  exit 1
fi
