# vod-scraper — long-video audio downloader (DietPi)

Watches one or more YouTube listings (channel tabs, playlists) on a schedule and
downloads the **audio** of every video longer than a duration gate, ignoring
shorts/clips/cuts, never fetching the same video twice, and keeping only the
newest few on disk. New downloads are registered in a media-server SQLite catalog
so they show up for playback.

**Audio only, by design.** The catalog is a listening app — the player streams
`/api/audio` and never touches the video — so downloading video was pure waste of
disk and bandwidth. One `.m4a` per recording (~100 MB for two hours, versus ~2 GB
for the same thing with video).

It's deliberately generic: the sources, duration gate, schedule and timezone are
all set in config — see [`vod-scraper.conf.example`](vod-scraper.conf.example).

Target box: a Raspberry Pi / DietPi (Debian, systemd). Works regardless of the box
clock — all dates/times are evaluated in the configured `TZ_NAME`.

## How it's wired

Two single-responsibility steps, joined by systemd:

1. **`vod-download.sh`** — pure downloader. Fetches the audio of every new long
   video into `DEST`. Knows nothing about the database.
2. **`vod-ingest.sh`** — idempotent reconciler. Scans `DEST` and inserts any file
   not already in the media-server SQLite DB. Knows nothing about downloading.

`vod-download.service` runs step 1; on success its `OnSuccess=vod-ingest.service`
fires step 2. The ingest is safe to run by hand anytime (re-register without
re-downloading). Both scripts read their settings from **`vod-scraper.conf`**.

## What a run does

1. **Scan** each source in `SOURCES` — one cheap flat request per source — and take
   the newest `KEEP_LATEST` entries longer than `MIN_DURATION`. Upcoming/live
   entries have no duration yet and are skipped.
2. **Filter** out duplicates (a video can appear in more than one source) and
   anything the download archive already knows about.
3. **Order** the survivors by real publish time and download the newest `MAX_NEW`
   of them, oldest first. Anything yt-dlp can't read (members-only, geo-blocked,
   taken down) is named in the log rather than silently skipped.
4. **Rotate** down to the newest `KEEP_LATEST` recordings, deleting each dropped
   `.m4a` with its `.info.json` sidecar. "Newest" means **publish date** (the
   `YYYY-MM-DD` filename prefix), not file mtime — see the note below.

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

`ffmpeg` (container fixups, and `ffprobe` for duration), `sqlite3` (DB writes),
and `jq` (reads chapter markers out of yt-dlp's info.json).

```bash
# yt-dlp — official build, uses system python3 (works on ARM), self-updates with -U
sudo wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp

# ffmpeg (provides ffprobe) + sqlite3 + jq
sudo apt-get update && sudo apt-get install -y ffmpeg sqlite3 jq
```

The media server must have created its database (run it once so migrations apply)
at the `DB_PATH` set in `vod-scraper.conf`. The ingest expects a `media` table with
`(date, title, video_path, audio_path, progress_seconds, total_seconds, chapters)`
columns. (`jq` is optional — without it the ingest still works, just stores no
chapters.)

## 2. Install the scripts, config + units

```bash
# from this directory, copied onto the Pi:
sudo install -m 755 vod-download.sh        /usr/local/bin/vod-download.sh
sudo install -m 755 vod-ingest.sh          /usr/local/bin/vod-ingest.sh
sudo install -m 644 vod-scraper.conf.example /etc/vod-scraper.conf   # then edit: SOURCES, DEST, DB_PATH ...
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
ls -lh "$DEST"                                # downloaded recordings (DEST from the config)
```

## Knobs (`vod-scraper.conf`)

All settings live in `vod-scraper.conf` (looked up via `$VOD_CONFIG`, then next to
the scripts, then `/etc/vod-scraper.conf`). Both scripts source it.

- `SOURCES` — **required**; a bash array of newest-first listing URLs. A channel
  splits its long-form output across tabs (`/videos` for uploads, `/streams` for
  past livestreams) and they don't overlap, so track both. Playlist URLs work too.
- `DEST` — download directory; also where the media server serves files from.
- `DB_PATH` — the media-server SQLite DB the ingest writes rows into.
- `KEEP_LATEST=14` — recordings kept on disk; older ones rotated out.
- `MIN_DURATION=3600` — duration gate (s); entries this long or shorter are ignored.
- `SCAN_DEPTH=50` — how many newest entries are scanned per source.
- `MAX_NEW=0` — max downloads per run; `0` means `KEEP_LATEST`. Stops a first run
  against a fresh channel from fetching a whole backlog it would only rotate away.
- `AUDIO_FORMAT=m4a` — output container.
- `YTDLP_ARGS` — extra yt-dlp flags applied to every call. Set
  `(--extractor-args "youtube:lang=es")` for a Spanish-language channel: YouTube
  otherwise serves titles machine-translated into the box's locale, and those
  translations end up in filenames and in the catalog.
- `TZ_NAME` — timezone all dates/times are evaluated in (default `UTC`).
- `COOKIES` — optional yt-dlp cookies file; leave empty for public sources. **Set
  this if the channel puts long uploads behind channel membership** — those are
  skipped (and named in the log) without a cookies file from a logged-in member.
- `PLAYLIST` — legacy single-URL alias for `SOURCES`, still honoured if `SOURCES`
  is unset.

## Database ingest

`vod-ingest.sh` reconciles `DEST` against the media-server DB: for every `*.m4a`
not already present, it reads the duration with `ffprobe` and INSERTs a row
(`date`, `title`, `audio_path` as an absolute path, `progress_seconds=0`,
`total_seconds=<duration>`, `chapters`). `video_path` is stored empty — unless a
legacy `.mp4` from the video-downloading era still sits next to the audio, in
which case it's recorded. It's idempotent — re-runs only add genuinely new files.
`date`/`title` are parsed from the `YYYY-MM-DD - Title [id].m4a` filename, where
the date is the video's publish date in `TZ_NAME`.

**Chapters:** the downloader passes `--write-info-json`, so each recording gets a
`<stem>.info.json` sidecar. The ingest distills its YouTube chapter markers into a
compact `[{start, title}]` JSON array (via `jq`) and stores it in the `chapters`
column; the media server serves it so the player can offer chapter navigation.
Videos without chapters (or without `jq`) just get an empty array. The file is
never split — chapters are metadata only.

It also **prunes**: rows under `DEST` whose file no longer exists on disk (e.g.
recordings the downloader rotated out) are deleted, so the catalog never shows
dead entries. A row is judged by its **audio** file — the thing the player streams
— so deleting a leftover `.mp4` next to a live `.m4a` does not drop the row or the
listening progress on it. Rows outside `DEST` are never touched.

## Notes

- **Output format:** `bestaudio[ext=m4a]` is YouTube's own AAC track, so writing
  `.m4a` is a **container copy** — no re-encode, near-instant on a Pi, iOS-native,
  and preferred over MP3, which would be a lossy transcode for no benefit here.
- **Titles:** YouTube auto-translates titles to the requesting locale, so a Spanish
  show can arrive as English. `YTDLP_ARGS=(--extractor-args "youtube:lang=es")`
  pins the original.
- **Date stamp:** filenames are prefixed with the video's publish date evaluated in
  `TZ_NAME`. yt-dlp's `upload_date` is deliberately **not** used: it's UTC and can
  land on the wrong day for a late-night broadcast.
- **Members-only content:** a channel can gate its long uploads behind membership.
  Those candidates are reported as `unavailable:` in the log with yt-dlp's reason;
  point `COOKIES` at a Netscape-format cookies file from a logged-in member to
  fetch them.
- **Keep yt-dlp current.** A stale build fails in a way that looks like something
  else: listings and metadata still read fine, then every download dies with
  `HTTP Error 403: Forbidden`. `sudo yt-dlp -U` fixes it. Old builds also print
  durations as floats (`2749.0`) where new ones print integers — the duration gate
  accepts both, but it's a sign the build is behind.
- **Persistence:** `Persistent=true` — if the box was off at the scheduled time, it
  runs once at the next boot.
- **Rotation orders by publish date, not mtime.** A backfill run downloads old
  episodes *today*, so they carry the newest mtime; an mtime sort would evict
  recent episodes to keep years-old ones. Filenames start with the publish date, so
  a plain reverse sort is newest-broadcast-first. Relatedly, the downloader skips
  any candidate older than the newest `KEEP_LATEST` — no point fetching an episode
  over a slow link only to delete it minutes later.
- **Dedup vs. rotation:** rotation deletes old recordings but never touches the
  download archive, so a rotated-out video is still remembered and won't re-download.
- **Partial failures:** one failing download doesn't abort the run; the rest still
  download and the run only reports failure if *every* attempted download failed.
