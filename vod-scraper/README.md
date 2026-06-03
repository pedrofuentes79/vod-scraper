# vod-scraper — playlist video downloader (DietPi)

Downloads the latest **full-length** video from a YouTube playlist on a schedule,
ignores shorter cuts/clips via a duration gate, never fetches the same video
twice, and keeps only the newest few on disk. New downloads are registered in a
media-server SQLite catalog so they show up for playback.

It's deliberately generic: the playlist, duration gate, schedule, timezone and an
optional "freshness" accept-window are all set in config — see
[`vod-scraper.conf.example`](vod-scraper.conf.example).

Target box: a Raspberry Pi / DietPi (Debian, systemd). Works regardless of the box
clock — all dates/times are evaluated in the configured `TZ_NAME`.

## How it's wired

Two single-responsibility steps, joined by systemd:

1. **`vod-download.sh`** — pure downloader. Fetches the latest full video into `DEST`.
   Knows nothing about the database.
2. **`vod-ingest.sh`** — idempotent reconciler. Scans `DEST` and inserts any file
   not already in the media-server SQLite DB. Knows nothing about downloading.

`vod-download.service` runs step 1; on success its `OnSuccess=vod-ingest.service`
fires step 2. The ingest is safe to run by hand anytime (re-register without
re-downloading). Both scripts read their settings from **`vod-scraper.conf`**.

## Files

| Repo file | Install to |
|-----------|-----------|
| `vod-download.sh` | `/usr/local/bin/vod-download.sh` |
| `vod-ingest.sh` | `/usr/local/bin/vod-ingest.sh` |
| `vod-scraper.conf` (from `.example`) | `/etc/vod-scraper.conf` |
| `vod-download.service` | `/etc/systemd/system/vod-download.service` |
| `vod-download.timer` | `/etc/systemd/system/vod-download.timer` |
| `vod-ingest.service` | `/etc/systemd/system/vod-ingest.service` |

## 1. Prerequisites (on the Pi)

`ffmpeg` (merge video+audio, and `ffprobe` for duration) and `sqlite3` (DB writes).

```bash
# yt-dlp — official build, uses system python3 (works on ARM), self-updates with -U
sudo wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp

# ffmpeg (provides ffprobe) + sqlite3
sudo apt-get update && sudo apt-get install -y ffmpeg sqlite3
```

The media server must have created its database (run it once so migrations apply)
at the `DB_PATH` set in `vod-scraper.conf`. The ingest expects a `media` table with
`(date, title, video_path, audio_path, progress_seconds, total_seconds)` columns.

## 2. Install the scripts, config + units

```bash
# from this directory, copied onto the Pi:
sudo install -m 755 vod-download.sh        /usr/local/bin/vod-download.sh
sudo install -m 755 vod-ingest.sh          /usr/local/bin/vod-ingest.sh
sudo install -m 644 vod-scraper.conf.example /etc/vod-scraper.conf   # then edit: PLAYLIST, DEST, DB_PATH ...
sudo install -m 644 vod-download.service   /etc/systemd/system/vod-download.service
sudo install -m 644 vod-ingest.service     /etc/systemd/system/vod-ingest.service
sudo install -m 644 vod-download.timer     /etc/systemd/system/vod-download.timer
sudo systemctl daemon-reload
sudo systemctl enable --now vod-download.timer
```

## 3. Verify

```bash
systemctl list-timers vod-download.timer     # next / last run
sudo systemctl start vod-download.service     # run once now (manual test)
journalctl -u vod-download.service -f         # follow download output
journalctl -u vod-ingest.service -f           # follow DB-ingest output
sudo systemctl start vod-ingest.service       # re-register files in the DB (no re-download)
ls -lh "$DEST"                                # downloaded videos (DEST from the config)
```

## Knobs (`vod-scraper.conf`)

All settings live in `vod-scraper.conf` (looked up via `$VOD_CONFIG`, then next to
the scripts, then `/etc/vod-scraper.conf`). Both scripts source it.

- `PLAYLIST` — **required**; the YouTube playlist URL to track.
- `DEST` — download directory; also where the media server serves files from.
- `DB_PATH` — the media-server SQLite DB the ingest writes rows into.
- `KEEP_LATEST=7` — videos kept on disk; older ones rotated out (mp4 + its m4a).
- `MIN_DURATION=5400` — duration gate (s) separating full videos from cuts/clips.
- `SCAN_DEPTH=50` — how many newest playlist entries to scan for a full video.
- `WINDOW_START` / `WINDOW_END` — **optional** accept window (both empty = disabled).
  When set, a video must have published in `[yesterday WINDOW_START, today WINDOW_END]`
  (in `TZ_NAME`) to be downloaded — handy for a daily broadcast fetched the next morning.
- `TZ_NAME` — timezone all dates/times are evaluated in (default `UTC`).
- `MERGE_FORMAT=mp4` — output container.
- `EXTRACT_AUDIO=true` — also write a separate `.m4a` (lossless copy of the AAC track).
- `COOKIES` — optional yt-dlp cookies file; leave empty for a public playlist.

## Database ingest

`vod-ingest.sh` reconciles `DEST` against the media-server DB: for every `*.mp4`
(plus its `.m4a` sidecar) not already present, it reads the duration with `ffprobe`
and INSERTs a row (`date`, `title`, `video_path`, `audio_path` as absolute paths,
`progress_seconds=0`, `total_seconds=<duration>`). It's idempotent — re-runs only
add genuinely new files. `date`/`title` are parsed from the
`YYYY-MM-DD - Title [id].mp4` filename, where the date is the date the downloader
stamped in (see notes).

It also **prunes**: rows under `DEST` whose file no longer exists on disk (e.g.
videos the downloader rotated out) are deleted, so the catalog never shows dead
entries. Rows outside `DEST` are never touched.

## Notes

- **Output format:** prefers **H.264/AAC** video merged into `.mp4` (plays
  everywhere, incl. iOS — note this caps video at 1080p, YouTube's max for H.264).
  With `EXTRACT_AUDIO=true`, a separate `.m4a` is written alongside — a **lossless
  copy** of YouTube's AAC track (no re-encode, near-instant, iOS-native; preferred
  over MP3, which would be a lossy transcode for no benefit here). `--keep-video`'s
  leftover pre-merge fragments (`*.f137.mp4`, `*.f140.m4a`, …) are cleaned up so only
  the final `.mp4` + `.m4a` remain.
- **Accept window (optional):** when `WINDOW_START`/`WINDOW_END` are set, the script
  only downloads if the candidate's publish time (yt-dlp `timestamp`) falls in
  `[yesterday WINDOW_START, today WINDOW_END]` in `TZ_NAME`. yt-dlp's `upload_date`
  is deliberately **not** used for this: it's UTC and can land on the wrong day for
  late-night broadcasts. Leave both empty to disable the window and just take the
  newest full video.
- **Date stamp:** filenames are prefixed with a date. With the window enabled, it's
  the computed "broadcast day"; otherwise it's the publish date in `TZ_NAME`.
- **Persistence:** `Persistent=true` — if the box was off at the scheduled time, it
  runs once at the next boot.
- **Dedup vs. rotation:** rotation deletes old videos (each `.mp4` plus its `.m4a`)
  but never touches the download archive, so a rotated-out video is still remembered
  and won't re-download.
