# Omafy

Spotify in your bar. Play, pause, skip, search, and queue music without opening
the Spotify app. A small librespot receiver plays audio locally as **Omafy**.

**Tiny footprint: ~34 MiB estimated total RAM vs ~1 GiB for Spotify** in a local
comparison — about **97% less**. This includes the receiver, service, and two
bar widgets. [Measurement details](#memory-footprint).

Requires Omarchy Quattro with Quickshell, Python 3, Bash/coreutils, `xdg-open`,
and Spotify API access. Local playback also requires `librespot` with its
PulseAudio backend and a working PulseAudio-compatible server (such as
PipeWire-Pulse). Playback control requires Spotify Premium.

## Setup

1. Install and enable the bar widget:

   ```bash
   omarchy plugin add https://github.com/Jared-Mac/omafy --enable
   ```

2. Create an app in the
   [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
   Add this **Redirect URI**, then save:

   ```
   http://127.0.0.1:8989/login
   ```

   Set **Spotify Developer client ID** in Omafy's widget settings to your app's
   client ID. The bundled ID belongs to the maintainer's development app;
   other users should use their own. While your app is in Development mode,
   add your Spotify account under **User Management**.

3. Click **Connect Spotify** in the bar and approve access in the browser.

4. Set up the local player (installs librespot's one-time sign-in and a
   user service that starts with your session):

   ```bash
   omarchy pkg add librespot
   ~/.config/omarchy/plugins/jaredm.omafy/bin/omafy-player setup
   ```

   Then middle-click the widget, or use **Play on this computer** in the popup.

Tokens are stored in `~/.local/state/omafy/token.json` (mode 0600) and
refreshed automatically.

The helpers honor `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and `XDG_CONFIG_HOME`.
Player setup installs a systemd drop-in with the selected cache path; rerun
`bin/omafy-player setup` after changing `XDG_CACHE_HOME`.

## Using it

| Input | Action |
|---|---|
| Left click | Open player: artwork, seek, shuffle/repeat, like, volume, devices |
| Middle click | Play / pause |
| Right click | Next track |
| Scroll | Spotify volume ±5% |
| Artwork click | Open the track in Spotify |

The popup has four tabs:

- **Now**: current track, controls, volume and devices.
- **Search**: songs, artists, albums and playlists. Click to play; hover a song
  and click **+** (or middle-click it) to add it to the queue.
- **Library**: Liked Songs, Recently played and your playlists. Open one to
  play or shuffle it, or play from any song onward.
- **Queue**: what plays next.

Keybinding-friendly IPC:

```bash
omarchy-shell omafy playPause   # also: playHere, next, previous, like, volumeUp, volumeDown, login, status, search, browse
```

The player helper also accepts `start`, `stop`, `restart`, `status`, and `logout`.

## Memory footprint

Local measurement on September 29, 2026, using proportional set size (PSS) to
avoid counting shared memory twice:

| Component | RAM |
|---|---:|
| Omafy receiver | 28 MiB |
| Omafy service + two bar widgets, estimated added cost | 6 MiB |
| **Omafy total, estimated** | **34 MiB** |
| **Spotify desktop, all nine processes** | **978–1,032 MiB** |

The widget estimate comes from three paired fresh offscreen shell runs with
and without Omafy, using the current cached state and closed popups. The common
shell baseline is subtracted; receiver and Spotify memory were sampled live.
This is one local comparison, not a fixed memory guarantee.
[Raw measurements](benchmarks/2026-09-29-memory.json).

## Remove

Stop the receiver, remove its credentials, and disconnect the bar before
removing the plugin:

```bash
~/.config/omarchy/plugins/jaredm.omafy/bin/omafy-player logout
~/.config/omarchy/plugins/jaredm.omafy/bin/omafy-auth logout
omarchy plugin remove jaredm.omafy
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omafy-player.service"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omafy-player.service.d/10-omafy-cache.conf"
systemctl --user daemon-reload
```

Cached artwork metadata and audio remain under `${XDG_CACHE_HOME:-~/.cache}/omafy`;
you can delete that directory to reclaim the disk space.

## License

[MIT](LICENSE). Librespot is a separate dependency with its own license.

## Caching

- `~/.cache/omafy/state.json` keeps liked flags per track (6h), active
  per-endpoint rate limits, and the last track so the bar is filled
  immediately after a shell restart.
- `~/.cache/omafy/librespot/` holds the receiver's credentials and an audio
  cache capped at 1 GB, so replayed songs don't download again.
- `~/.cache/omafy/library.json` keeps your playlist list, Liked Songs and
  Recently played (refreshed after 10 min / 2 min, shown instantly while
  refreshing) plus the contents of the last 30 opened playlists, keyed by
  Spotify's snapshot id so a playlist is only refetched when it changes.
  Search results are cached in memory for 10 minutes.
- Polling is relaxed (5s playing, 8s idle); an extra poll lands exactly when
  the current track ends, and progress is interpolated locally.

Library and playlist lists follow every page returned by Spotify. Caches are
tied to a sign-in, preserved across token refreshes, and cleared on Disconnect
or a new sign-in. Older caches without this association are ignored.

## Settings (`~/.config/omarchy/shell.json` entry)

| Key | Default | |
|---|---|---|
| `showArtist` | `true` | Append the artist to the bar label |
| `hideWhenIdle` | `false` | Hide the widget when nothing is playing |
| `greenWhenPlaying` | `true` | Spotify-green icon while playing |
| `maxLabelWidth` | `220` | Label width cap in px |
| `pollIntervalMs` | `5000` | Poll rate while playing (idle polls every 8s) |
| `clientId` | `""` | Override the built-in client ID |

## Layout

- `Service.qml` owns auth, polling and API calls, once per shell
- `BarWidget.qml` holds the bar label and popup, one per monitor
- `Spotify.js` holds response parsing and formatting
- `bin/omafy-auth` runs the PKCE login, token storage and refresh
- `bin/omafy-player` + `systemd/omafy-player.service` run the librespot receiver

```bash
bin/omafy-auth status | login | token | logout
```

`bin/omafy-auth token --force-refresh` obtains a new access token even when the
stored one has not expired. The service uses this when Spotify rejects a token.

## Development checks

```bash
bash tests/run.sh
```

Requires Node.js and Python 3. Tests cover authentication races, account cache
isolation, pagination, command failures, playback sequencing, and receiver
setup. When Quickshell is installed, the runner also loads the service offscreen
with temporary state and cache directories. Tests use dummy credentials and
mock network/service calls; they do not control Spotify playback.
