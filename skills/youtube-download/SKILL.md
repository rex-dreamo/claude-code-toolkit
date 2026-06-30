---
name: youtube-download
visibility: public
description: Use whenever the user wants a video file saved to disk from the web. Strong triggers: any pasted URL from youtube.com, youtu.be, youtube.com/shorts, vimeo.com, tiktok.com, twitter.com / x.com, reddit.com, or instagram.com combined with intent to keep it locally — phrasings like save, download, grab, rip, pull, archive, keep, get, fetch, snag. Also use for adjacent yt-dlp workflows on the same URL: extracting audio (mp3, "just the audio"), burning in or embedding subtitles, capping resolution (1080p / 4K), playlists, time ranges, age-restricted or login-required videos, saving to a specific folder or NAS path, and scheduling recurring downloads (cron a channel, watch a playlist). Default output is a single best-quality mp4; flags handle variations. Do NOT trigger for: embedding a video in HTML/markdown, fixing audio/sync issues in an existing local file, YouTube Data API or analytics questions, recommending third-party downloader websites, or generic ffmpeg problems unrelated to fetching the source.
---

# YouTube Download (yt-dlp)

Download YouTube (and other yt-dlp-supported) videos at the best available quality, output as a single `.mp4` file.

## Required tooling

`yt-dlp` and `ffmpeg` must both be on `PATH`. `ffmpeg` is needed because YouTube serves video and audio as separate DASH streams above 360p — yt-dlp downloads them in parallel and ffmpeg muxes them into one mp4. If either is missing, install with `brew install yt-dlp ffmpeg` on macOS or the user's platform equivalent and continue.

## The command

```bash
yt-dlp \
  -f "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b" \
  --merge-output-format mp4 \
  -P "$HOME/Downloads" \
  -o "%(title).80s [%(id)s].%(ext)s" \
  "<URL>"
```

Default save location is `~/Downloads` — set via `-P` ("paths") so the output template stays clean. Override only when the user explicitly names a different folder ("save to ~/Movies", "drop it in /volume1/media/Tech", "put it in this project's `assets/`"). Swap the `-P` value in those cases; don't add a second `-P`. If the user just pastes a URL with no folder mention, `~/Downloads` is the right call — don't ask.

### Why this format selector

The selector is a fallback chain, read left to right:

1. `bv*[ext=mp4]+ba[ext=m4a]` — best video-only mp4 stream + best m4a audio. This is what runs for almost every video. It reaches 4K/8K when available because we did **not** restrict to H.264 (avc1); the mp4 container holds VP9 and AV1 too, and YouTube only serves H.264 up to 1080p.
2. `b[ext=mp4]` — fall back to a pre-muxed mp4 if separate streams aren't offered (very rare, usually only on short/low-res clips).
3. `bv*+ba/b` — last resort: best of anything, and `--merge-output-format mp4` remuxes the result into mp4. Used when a site doesn't expose mp4 at all.

`--merge-output-format mp4` instructs ffmpeg to produce an `.mp4` output even when the inputs are webm/m4a. This is the load-bearing flag that delivers on the "mp4 format" promise.

### Why this output template

`%(title).80s [%(id)s].%(ext)s` does three things:

- `%(title).80s` truncates the video title at 80 characters. macOS allows 255-byte filenames but emojis are 4 bytes each and long titles plus a path prefix can hit the limit unexpectedly.
- `[%(id)s]` appends the 11-character YouTube video ID in brackets. YouTube titles are not unique — downloading two "Trailer" videos into the same folder would otherwise collide. The bracketed ID is also how yt-dlp itself prefers to disambiguate re-downloads.
- `%(ext)s` is filled in by yt-dlp after the merge, so the file ends up as `.mp4`.

## Common variations

The user may ask for adjustments. Apply only what's requested — don't pile on flags.

| Ask | Add |
|---|---|
| "Just the audio" / "extract mp3" | `-x --audio-format mp3` (drops video, transcodes audio). For best-quality audio without re-encoding, use `-f ba[ext=m4a]` and skip `-x`. |
| "With subtitles burned in" | `--write-subs --embed-subs --sub-langs en` (embeds soft subs into the mp4 — players can toggle them). |
| "Cap at 1080p" / "save bandwidth" | Change `bv*[ext=mp4]` to `bv*[ext=mp4][height<=1080]`. |
| "Make sure it plays everywhere" / "use H.264" / "for my smart TV / old phone" | Append `-S "vcodec:h264,res,br"` after `-f ...`. Forces H.264 (avc1) over AV1/VP9 within the mp4 container — max compatibility with older players, smart TVs, Windows Media Player, pre-iOS-17. Caps effective resolution at 1080p because YouTube doesn't serve H.264 above that. |
| "Download the whole playlist" | Add `--yes-playlist` and switch `-o` to `"%(playlist_title)s/%(playlist_index)s - %(title).80s [%(id)s].%(ext)s"` so files land in a per-playlist folder, numbered in order. |
| "It's age-restricted" / "login required" | Add `--cookies-from-browser <browser>` where browser is `chrome`, `safari`, `firefox`, `brave`, etc. Use the browser the user is signed in with. |
| "Specific time range" | `--download-sections "*MM:SS-MM:SS"` and add `--force-keyframes-at-cuts` for clean cuts (slower because of re-encoding around the cut points). |
| "Save it somewhere else" (any folder that isn't `~/Downloads`) | Change `-P "$HOME/Downloads"` to the requested path, e.g. `-P "$HOME/Movies"` or `-P "/Volumes/External/clips"`. The folder must already exist — yt-dlp won't create deep paths. |

## Behavior to follow

- **Don't pipe the command through `| tail` or similar.** yt-dlp's progress lines are useful and they redraw on a single line; suppressing them just hides whether the download is making progress.
- **Run it without `nohup`/`&`.** A YouTube video at typical residential bandwidth completes in seconds-to-minutes; the user is waiting on the result, and backgrounding makes failure modes (geo-blocks, age gates, 403s) silent.
- **Honor what the user already specified.** If they said "save as `talk.mp4`", override the output template with `-o "talk.%(ext)s"` instead of layering on top of the default naming.
- **Report what got produced.** When the download finishes, tell the user the resulting filename and its size — yt-dlp prints both, but surface them so the user doesn't have to scan progress output.

## Failure modes worth knowing

- **`ERROR: ... Sign in to confirm your age`** — age-restricted, needs `--cookies-from-browser <browser>`.
- **`ERROR: ... Video unavailable ... not available in your country`** — geo-blocked. yt-dlp can sometimes bypass with `--geo-bypass-country US`; if that fails, the video genuinely isn't reachable without a VPN.
- **`ERROR: Postprocessing: ffprobe and ffmpeg not found`** — ffmpeg isn't installed or isn't on `PATH`. Install it before retrying.
- **`HTTP Error 403`** on a fresh download — usually means the YouTube player JS changed and yt-dlp is out of date. Run `yt-dlp -U` (or `brew upgrade yt-dlp`) and retry.
- **Silent stall after "Downloading m3u8 information"** — the video is a live stream or premiere. Add `--live-from-start` for ongoing live streams, or wait for the premiere to end.

If you hit any of these, surface the diagnosis and the one-line fix instead of just relaying the error.
