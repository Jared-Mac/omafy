.pragma library

var API_BASE = "https://api.spotify.com/v1"
var DEFAULT_CLIENT_ID = "8830ae6c6cd24316aa148cd3cce88bdb"

function nextRepeatState(state) {
  if (state === "off") return "context"
  if (state === "context") return "track"
  return "off"
}

// Largest artwork is used for the popup; Spotify lists images widest first.
function pickImage(images) {
  if (!Array.isArray(images) || images.length === 0) return ""
  return String(images[0].url || "")
}

function parsePlayer(payload) {
  var item = payload && payload.item
  if (!item) return { hasTrack: false }

  var episode = item.type === "episode"
  var artists = []
  if (Array.isArray(item.artists)) {
    for (var i = 0; i < item.artists.length; i++) artists.push(item.artists[i].name)
  }
  var device = payload.device || {}

  return {
    hasTrack: true,
    isPlaying: payload.is_playing === true,
    type: String(item.type || "track"),
    uri: String(item.uri || ""),
    url: item.external_urls ? String(item.external_urls.spotify || "") : "",
    title: String(item.name || ""),
    artist: episode ? String(item.show ? item.show.publisher || item.show.name : "") : artists.join(", "),
    album: episode ? String(item.show ? item.show.name : "") : String(item.album ? item.album.name : ""),
    artUrl: pickImage(episode ? (item.images || (item.show && item.show.images)) : (item.album && item.album.images)),
    durationMs: Number(item.duration_ms) || 0,
    progressMs: Number(payload.progress_ms) || 0,
    shuffle: payload.shuffle_state === true,
    repeatState: String(payload.repeat_state || "off"),
    deviceId: String(device.id || ""),
    deviceName: String(device.name || ""),
    deviceType: String(device.type || ""),
    supportsVolume: device.supports_volume === true,
    volume: device.volume_percent === null || device.volume_percent === undefined ? -1 : Number(device.volume_percent),
    disallows: (payload.actions && payload.actions.disallows) || {}
  }
}

function errorMessage(status, payload) {
  var reason = payload && payload.error ? (payload.error.reason || payload.error.message || "") : ""
  if (reason === "NO_ACTIVE_DEVICE") return "No active device. Pick one below."
  if (reason === "PREMIUM_REQUIRED" || status === 403) return "Playback control requires Spotify Premium."
  if (status === 429) return "Rate limited by Spotify; retrying shortly."
  if (status === 404) return "No active device. Pick one below."
  return reason ? String(reason) : "Spotify returned HTTP " + status
}

function formatTime(ms) {
  var total = Math.max(0, Math.floor(ms / 1000))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var seconds = total % 60
  var ss = seconds < 10 ? "0" + seconds : String(seconds)
  if (hours > 0) return hours + ":" + (minutes < 10 ? "0" + minutes : minutes) + ":" + ss
  return minutes + ":" + ss
}

function deviceGlyph(type) {
  switch (String(type || "").toLowerCase()) {
  case "computer": return "󰍹"
  case "smartphone": return "󰄜"
  case "tablet": return "󰓶"
  case "speaker": return "󰓃"
  case "tv": return "󰔂"
  case "castvideo":
  case "castaudio": return "󰄙"
  case "automobile": return "󰄋"
  case "gameconsole": return "󰊴"
  default: return "󰓃"
  }
}

function repeatGlyph(state) {
  return state === "track" ? "󰑘" : "󰑖"
}

// ---- Library / search normalisation. Every list the popup shows uses one
// small row shape so it can be cached compactly and rendered by MediaRow:
//   { kind, id, uri, title, subtitle, image, durationMs, snapshot, count }

// Smallest image that is still at least `min` px, so rows don't pull 640px art.
function pickThumb(images, min) {
  if (!Array.isArray(images) || images.length === 0) return ""
  var best = images[0]
  for (var i = 0; i < images.length; i++) {
    var width = Number(images[i].width) || 0
    if (width >= (min || 64) && width <= (Number(best.width) || Infinity)) best = images[i]
  }
  return String(best.url || "")
}

function artistNames(artists) {
  var names = []
  if (Array.isArray(artists)) for (var i = 0; i < artists.length; i++) if (artists[i]) names.push(artists[i].name)
  return names.join(", ")
}

function normalize(item) {
  if (!item || !item.uri) return null
  switch (item.type) {
  case "track":
    return { kind: "track", id: item.id, uri: item.uri, title: String(item.name || ""),
      subtitle: artistNames(item.artists), image: pickThumb(item.album && item.album.images),
      durationMs: Number(item.duration_ms) || 0 }
  case "episode":
    return { kind: "episode", id: item.id, uri: item.uri, title: String(item.name || ""),
      subtitle: item.show ? String(item.show.name || "") : "Episode",
      image: pickThumb(item.images || (item.show && item.show.images)), durationMs: Number(item.duration_ms) || 0 }
  case "album":
    return { kind: "album", id: item.id, uri: item.uri, title: String(item.name || ""),
      subtitle: "Album · " + artistNames(item.artists), image: pickThumb(item.images) }
  case "artist":
    return { kind: "artist", id: item.id, uri: item.uri, title: String(item.name || ""),
      subtitle: "Artist", image: pickThumb(item.images) }
  case "playlist":
    var total = item.items ? item.items.total : (item.tracks ? item.tracks.total : 0)
    return { kind: "playlist", id: item.id, uri: item.uri, title: String(item.name || ""),
      subtitle: "Playlist · " + String(item.owner ? item.owner.display_name || "" : "")
        + (total ? " · " + total + " songs" : ""),
      image: pickThumb(item.images), snapshot: String(item.snapshot_id || ""), count: Number(total) || 0 }
  }
  return null
}

function normalizeList(items, unwrapKey) {
  var result = []
  if (!Array.isArray(items)) return result
  for (var i = 0; i < items.length; i++) {
    var entry = items[i]
    // Playlist entries moved from { track } to { item } in the 2026 API.
    if (entry && unwrapKey) entry = entry.item || entry.track || entry[unwrapKey]
    var row = normalize(entry)
    if (row) result.push(row)
  }
  return result
}

function parseSearch(payload) {
  var sections = []
  var order = [["tracks", "Songs"], ["artists", "Artists"], ["albums", "Albums"], ["playlists", "Playlists"]]
  for (var i = 0; i < order.length; i++) {
    var block = payload ? payload[order[i][0]] : null
    var rows = normalizeList(block ? block.items : [])
    if (rows.length > 0) sections.push({ title: order[i][1], rows: rows })
  }
  return sections
}

function quotaMessage(status, payload, what) {
  if (status === 429) return "Spotify's quota for this app is used up for now. " + what + " will load when it resets."
  if (status === 403) return "Reconnect Spotify to allow " + what.toLowerCase() + "."
  return errorMessage(status, payload)
}
