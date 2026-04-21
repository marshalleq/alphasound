# Ideas / TODO

Things considered but not built. Roughly ordered by perceived value.

## Display features

- **Roon metadata** — Roon Bridge doesn't expose track info locally; would need a Roon Extension that talks to the Core's REST API (port 9100, OAuth-style auth flow, must be authorised once in the Roon app). [`roonapi`](https://github.com/pavoni/pyroon) Python lib exists. ~150 lines of Python + ~5 MB more deps. Most-asked missing piece.
- **Bluetooth A2DP track info** — A2DP carries audio only; AVRCP carries metadata but bluez-alsa doesn't expose it. Would read from D-Bus `org.bluez.MediaPlayer1` to get title/artist when a phone's connected over BT. ~50 lines via `dasbus` or raw D-Bus.
- **Album art ambient colour** — extract the dominant colour with PIL, use as background tint or accent. ~10 lines.
- **Display themes** — light / dark / neon / minimalist via a config flag (`ALPHASOUND_DISPLAY_THEME=...`). Just colour swaps in `render()`.
- **Idle clock** — when nothing's playing, show a big clock + date instead of "Waiting…". RTC isn't available without internet, so date would be wrong until first NTP sync (currently never in standalone mode).
- **Volume bar** — show the current `ALPHASOUND_VOLUME_MAX_DB` setting visually. Easy if we keep volume read from config.
- **Source indicator** — "AirPlay from Quentin's iPhone" — we already get the client name via shairport-sync's `snua` code.
- **VU meter / spectrum analyzer** — tap the audio stream pre-DAC, run FFT (numpy already shipped), render bars. ~100 lines. Cool for HDMI use cases. Adds a bit of CPU.
- **Multi-screen** — when both an SPI screen AND HDMI are connected, render to both with appropriate layouts.

## Audio / playback

- **Volume control auto-detect** — for setups where the user *does* want phone volume control (HDMI to home stereo, USB DAC), detect whether the active ALSA output has a hardware mixer and conditionally set `ignore_volume_control = "no"` in shairport-sync. Default car-line-out behaviour stays.
- **Roon + AirPlay simultaneous** — both grab the audio device exclusively today. ALSA dmix could let them coexist but adds latency complexity. Probably not worth it.

## Network / updates

- **Delta apkovl updates** — `xdelta3` between releases, ~5–10× smaller download. Worth it only when the user's doing frequent updates over cellular.
- **Auto-update check** — periodic background check for new releases when in client mode, optional notification in the web UI. Currently manual via "Check for updates" button.
- **BT pairing auto-save** — currently saved at boot; pairings made *during* a session are lost on power cut. Could add an inotify watcher on `/var/lib/bluetooth/` that syncs to SD on change.
- **HTTPS for the web UI** — would let iOS keychain save credentials more reliably, but self-signed certs warn every visit and Let's Encrypt requires public DNS. Probably not worth it.

## Build / packaging

- **Persistent host keys for Roon endpoint identity** — already done at filesystem level via the persist symlink, but verify it's actually working before relying on it.
- **Image variants** — a "minimal" build without Python/Pillow/numpy (~30 MB smaller) for users who don't want the display feature at all.
