# Omafy

Spotify for the Omarchy bar without the Spotify app: a Web API remote
control in the bar plus a ~30-50 MB librespot receiver that plays audio
locally as the Spotify Connect device "Omafy".

## Setup

1. In the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard),
   open the app for client ID `8830ae6c6cd24316aa148cd3cce88bdb` and add this
   **Redirect URI**, then save:

   ```
   http://127.0.0.1:8989/login
   ```

   While the app is in Development mode, your Spotify account must also be
   listed under **User Management**.

2. Install the plugin by linking this checkout into the plugin directory:

   ```bash
   ln -sfn ~/Work/omafy ~/.config/omarchy/plugins/jaredm.omafy
   omarchy-shell shell rescanPlugins
   omarchy plugin enable jaredm.omafy
   ```

3. Click **Connect Spotify** in the bar and approve access in the browser.

4. Set up the local player (installs librespot's one-time sign-in and a
   user service that starts with your session):

   ```bash
   omarchy pkg add librespot
   bin/omafy-player setup     # also: start | stop | restart | status | logout
   ```

   Then middle-click the widget, or use **Play on this computer** in the popup.

Tokens are stored in `~/.local/state/omafy/token.json` (mode 0600) and
refreshed automatically.

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

Playback control requires Spotify Premium. Free accounts still see what's playing.

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
