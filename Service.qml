import QtQuick
import Quickshell
import Quickshell.Io
import "Spotify.js" as Spotify

// Headless owner of Spotify state. One instance per shell, shared by the bar
// widget on every monitor, so polling and token refreshes happen once.
Item {
  id: root

  readonly property string authHelper: String(Qt.resolvedUrl("bin/omafy-auth")).replace(/^file:\/\//, "")

  // Pushed in by the bar widget from its shell.json entry.
  property string clientId: Spotify.DEFAULT_CLIENT_ID
  property int activePollMs: 5000
  property int idlePollMs: 8000

  // ---- Auth
  property bool authChecked: false
  property bool loggedIn: false
  property bool loggingIn: false
  property bool loginRestart: false
  property bool loginCancelled: false
  readonly property string redirectUri: "http://127.0.0.1:8989/login"
  property string accessToken: ""
  property real tokenExpiresAt: 0
  property var tokenWaiters: []
  property int sessionGeneration: 0
  property bool authEnabled: true
  property bool tokenBusy: false
  property bool forceTokenRefresh: false
  property bool loginBusy: false
  property bool loggingOut: false
  property bool loginAfterLogout: false
  property string cacheKey: ""
  property string lastError: ""

  // ---- Playback
  property bool hasTrack: false
  property bool isPlaying: false
  property string itemType: "track"
  property string trackUri: ""
  property string trackUrl: ""
  property string title: ""
  property string artist: ""
  property string album: ""
  property string artUrl: ""
  property real durationMs: 0
  property real progressMs: 0
  property real progressStamp: 0
  property bool shuffle: false
  property string repeatState: "off"
  property int volume: -1
  property bool supportsVolume: false
  property string deviceId: ""
  property string deviceName: ""
  property string deviceType: ""
  property bool liked: false
  property bool likedKnown: false
  property var devices: []
  property var disallows: ({})

  // Wall clock that advances only while playing, so bound progress text
  // moves without re-polling Spotify every second.
  property real now: Date.now()
  readonly property real position: hasTrack
    ? Math.min(durationMs, progressMs + (isPlaying ? Math.max(0, now - progressStamp) : 0))
    : 0

  property string localDeviceName: "Omafy"
  property int playHereAttempts: 0
  property string pendingPlayDevice: ""
  readonly property bool localIsActive: hasTrack && deviceName === localDeviceName

  // Spotify rate-limits per endpoint (the library check can be locked out for
  // hours while playback stays fine), so backoff is tracked per route.
  property var backoffUntil: ({})
  property int lastPollStatus: 0

  // ---- Disk cache ($XDG_CACHE_HOME/omafy/state.json): liked flags per track,
  // live rate limits, and the last track so the bar isn't blank after a
  // shell restart.
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/omafy"
  readonly property int likedTtlMs: 6 * 3600 * 1000
  readonly property int likedCacheMax: 2000
  property var likedCache: ({})
  property real lastPollAt: 0
  property int volumeTarget: -1

  // ---- Public actions

  // Spotify reports some failures (e.g. a redirect URI mismatch) on its own
  // page without ever calling back, so a second click restarts the attempt
  // instead of leaving the helper waiting out its timeout.
  function login() {
    lastError = ""
    if (loggingOut) {
      loginAfterLogout = true
      return
    }
    if (loginBusy) {
      loginRestart = true
      loginCancelled = false
      loginProcess.running = false
      return
    }
    loginCancelled = false
    loggingIn = true
    loginBusy = true
    loginProcess.command = [authHelper, "login", "--client-id", clientId]
    loginProcess.running = true
  }

  function cancelLogin() {
    loginRestart = false
    loginAfterLogout = false
    loginCancelled = loginBusy
    if (loginBusy) loginProcess.running = false
    loggingIn = false
  }

  function logout() {
    if (loggingOut) return
    loggingOut = true
    authEnabled = false
    cancelLogin()
    resetSession()
    if (tokenBusy) tokenProcess.running = false
    // Wait for helpers to exit before deleting their token file, so a late
    // refresh or sign-in cannot recreate it after Disconnect.
    completeLogout()
  }

  function completeLogout() {
    if (loggingOut && !tokenBusy && !loginBusy && !logoutProcess.running)
      logoutProcess.running = true
  }

  function resetSession() {
    sessionGeneration++
    accessToken = ""
    tokenExpiresAt = 0
    tokenWaiters = []
    forceTokenRefresh = false
    loggedIn = false
    cacheKey = ""
    resetAccountState()
    saveCache()
    saveLibrary()
  }

  function resetAccountState() {
    trackEndPoll.stop()
    settlePoll.stop()
    playAfterTransfer.stop()
    volumeDebounce.stop()
    noticeTimer.stop()
    saveCacheSoon.stop()
    saveLibrarySoon.stop()
    clearPlayback()
    devices = []
    liked = false
    shuffle = false
    repeatState = "off"
    deviceType = ""
    disallows = ({})
    pendingPlayDevice = ""
    playHereAttempts = 0
    volumeTarget = -1
    likedCache = ({})
    browseCache = ({})
    backoffUntil = ({})
    lastPollAt = 0
    lastPollStatus = 0
    grantedScope = ""
    wantedScope = ""
    searchQuery = ""
    searchSections = []
    searchLoading = false
    searchError = ""
    playlists = []
    playlistsLoading = false
    playlistsError = ""
    closeList()
    queueRows = []
    queueLoading = false
    queueError = ""
    notice = ""
    lastError = ""
  }

  // Resume on the local librespot receiver. librespot takes a transfer but
  // ignores its play flag, so follow up with an explicit play once the
  // session has landed.
  function playHere() {
    lastError = ""
    withLocalDevice(function(id) {
      root.api("PUT", "/me/player", { device_ids: [id], play: true }, function(status, payload) {
        if (!Spotify.isSuccess(status)) {
          root.lastError = Spotify.errorMessage(status, payload)
          return
        }
        root.pendingPlayDevice = id
        playAfterTransfer.restart()
      })
    })
  }

  // Resolve the local receiver's device id, starting its user service first
  // when Spotify doesn't list it yet (it needs a moment to register).
  function withLocalDevice(callback) {
    if (!authEnabled) return
    playHereAttempts = 0
    if (!localPlayerStarter.running) localPlayerStarter.running = true
    findLocalDevice(callback)
  }

  function findLocalDevice(callback) {
    api("GET", "/me/player/devices", null, function(status, payload) {
      if (status !== 200) {
        root.lastError = Spotify.errorMessage(status, payload)
        return
      }
      if (status === 200 && payload && Array.isArray(payload.devices)) root.devices = payload.devices
      var device = root.localDevice()
      if (device) callback(device.id)
      else if (++root.playHereAttempts < 8) root.later(1500, function() { root.findLocalDevice(callback) })
      else root.lastError = "The Omafy receiver didn't come online. Try: omafy-player restart"
    })
  }

  function localDevice() {
    for (var i = 0; i < devices.length; i++) {
      if (String(devices[i].name) === localDeviceName) return devices[i]
    }
    return null
  }

  function playPause() {
    if (!hasTrack) {
      playHere()
      return
    }
    var playing = isPlaying
    applyOptimistic({ isPlaying: !playing })
    command("PUT", playing ? "/me/player/pause" : "/me/player/play")
  }

  function next() { command("POST", "/me/player/next") }
  function previous() {
    // Spotify's own clients restart the track after a few seconds in.
    if (position > 3000) seek(0)
    else command("POST", "/me/player/previous")
  }

  function seek(ms) {
    ms = Math.max(0, Math.round(ms))
    applyOptimistic({ progressMs: ms })
    command("PUT", "/me/player/seek?position_ms=" + ms)
  }

  function setVolume(percent) {
    if (!supportsVolume) return
    volumeTarget = Math.max(0, Math.min(100, Math.round(percent)))
    volume = volumeTarget
    volumeDebounce.restart()
  }

  function nudgeVolume(delta) {
    if (!supportsVolume || volume < 0) return
    setVolume((volumeTarget >= 0 ? volumeTarget : volume) + delta)
  }

  function toggleShuffle() {
    var next = !shuffle
    shuffle = next
    command("PUT", "/me/player/shuffle?state=" + next)
  }

  function cycleRepeat() {
    var next = Spotify.nextRepeatState(repeatState)
    repeatState = next
    command("PUT", "/me/player/repeat?state=" + next)
  }

  // When Spotify won't say whether the track is saved (the library check is
  // often rate-limited), treat it as not liked: the click saves it.
  function toggleLike() {
    if (!trackUri) return
    var removing = likedKnown && liked
    var uri = trackUri
    liked = !removing
    likedKnown = true
    api(removing ? "DELETE" : "PUT", "/me/library?uris=" + encodeURIComponent(uri), null,
      function(status, payload) {
        if (status >= 200 && status < 300) {
          root.rememberLiked(uri, !removing)
          root.flash(removing ? "Removed from Liked Songs" : "Added to Liked Songs")
          return
        }
        if (uri === root.trackUri) {
          root.liked = removing
          root.likedKnown = !!root.likedCache[uri]
        }
        root.lastError = Spotify.quotaMessage(status, payload, "Liking songs")
      })
  }

  function transferTo(id) {
    if (!id) return
    command("PUT", "/me/player", { device_ids: [id], play: true })
  }

  function refreshDevices() {
    if (!loggedIn) return
    api("GET", "/me/player/devices", null, function(status, payload) {
      if (status === 200 && payload && Array.isArray(payload.devices)) root.devices = payload.devices
    })
  }

  function openInSpotify() {
    if (trackUrl) Quickshell.execDetached(["xdg-open", trackUrl])
  }

  function poll() {
    if (!loggedIn) return
    api("GET", "/me/player?additional_types=episode", null, function(status, payload) {
      root.lastPollStatus = status
      root.lastPollAt = Date.now()
      if (status === 204 || (status === 200 && !payload)) {
        root.clearPlayback()
      } else if (status === 200) {
        root.applyPlayer(payload)
      }
    })
  }

  // ---- Browse: search, library lists, queue
  //
  // Everything the browse tabs show goes through a small keyed cache. Library
  // lists are served stale-while-revalidate and persisted to
  // $XDG_CACHE_HOME/omafy/library.json; playlist contents are keyed by the
  // playlist's snapshot id, so they are only refetched when the playlist
  // actually changes. Search results live in memory for a few minutes.

  property string grantedScope: ""
  property string wantedScope: ""
  readonly property bool needsReconnect: {
    if (!loggedIn || wantedScope === "") return false
    var granted = " " + grantedScope + " "
    var wanted = wantedScope.split(" ")
    for (var i = 0; i < wanted.length; i++) if (granted.indexOf(" " + wanted[i] + " ") < 0) return true
    return false
  }

  property var browseCache: ({})
  readonly property int searchTtlMs: 10 * 60 * 1000
  readonly property int libraryTtlMs: 10 * 60 * 1000
  readonly property int recentTtlMs: 2 * 60 * 1000

  property string searchQuery: ""
  property var searchSections: []
  property bool searchLoading: false
  property string searchError: ""

  property var playlists: []
  property bool playlistsLoading: false
  property string playlistsError: ""

  // The list opened from Library: { kind: "playlist"|"liked"|"recent", id, uri, title, image, rows }
  property var openList: null
  property bool openListLoading: false
  property string openListError: ""

  property var queueRows: []
  property bool queueLoading: false
  property string queueError: ""

  property string notice: ""

  function later(ms, fn) {
    var generation = sessionGeneration
    var timer = delayComponent.createObject(root, { interval: ms })
    timer.triggered.connect(function() {
      if (generation === root.sessionGeneration && root.authEnabled) fn()
      timer.destroy()
    })
    timer.start()
  }

  function flash(message) {
    notice = message
    noticeTimer.restart()
  }

  function cacheEntry(key, ttl) {
    var entry = browseCache[key]
    if (!entry) return undefined
    return ttl < 0 || Date.now() - entry.t < ttl ? entry.v : undefined
  }

  function staleEntry(key) {
    var entry = browseCache[key]
    return entry ? entry.v : undefined
  }

  function remember(key, value) {
    var next = Object.assign({}, browseCache)
    next[key] = { t: Date.now(), v: value }
    // Search results are memory-only; keep just the latest few dozen.
    var searches = Object.keys(next).filter(function(k) { return k.indexOf("search:") === 0 })
    if (searches.length > 40) {
      searches.sort(function(a, b) { return next[a].t - next[b].t })
      for (var i = 0; i < searches.length - 40; i++) delete next[searches[i]]
    }
    browseCache = next
    if (key.indexOf("search:") !== 0) saveLibrarySoon.restart()
  }

  // Follow every page before caching the list as complete.
  function fetchPaged(path, unwrapKey, done, rows) {
    rows = rows || []
    api("GET", path, null, function(status, payload) {
      if (status !== 200 || !payload) {
        done(status, rows, payload)
        return
      }
      rows = rows.concat(Spotify.normalizeList(payload.items, unwrapKey))
      if (payload.next)
        root.fetchPaged(String(payload.next).replace(Spotify.API_BASE, ""), unwrapKey, done, rows)
      else
        done(200, rows, payload)
    })
  }

  function search(query) {
    query = String(query || "").trim()
    searchQuery = query
    searchError = ""
    if (query === "") {
      searchSections = []
      searchLoading = false
      return
    }
    var key = "search:" + query.toLowerCase()
    var hit = cacheEntry(key, searchTtlMs)
    if (hit) {
      searchSections = hit
      searchLoading = false
      return
    }
    searchLoading = true
    fetchSearch(query, key, 0)
  }

  function fetchSearch(query, key, attempt) {
    api("GET", "/search?type=track,artist,album,playlist&limit=6&q=" + encodeURIComponent(query), null,
      function(status, payload) {
        if (query !== root.searchQuery) return
        // Spotify's search intermittently answers 502; a retry usually lands.
        if (status >= 500 && attempt < 3) {
          root.later(350 * (attempt + 1), function() { root.fetchSearch(query, key, attempt + 1) })
          return
        }
        root.searchLoading = false
        if (status === 200) {
          var sections = Spotify.parseSearch(payload)
          root.remember(key, sections)
          root.searchSections = sections
        } else {
          root.searchError = Spotify.quotaMessage(status, payload, "Search")
        }
      })
  }

  function loadPlaylists(force) {
    var fresh = cacheEntry("playlists", libraryTtlMs)
    var stale = staleEntry("playlists")
    if (stale) playlists = stale
    if (fresh && !force) return
    if (playlistsLoading) return
    playlistsLoading = true
    playlistsError = ""
    fetchPaged("/me/playlists?limit=50", null, function(status, rows, payload) {
      root.playlistsLoading = false
      if (status === 200) {
        root.playlists = rows
        root.remember("playlists", rows)
      } else {
        root.playlistsError = Spotify.quotaMessage(status, payload, "Playlists")
      }
    })
  }

  function openPlaylist(row) {
    var key = "playlist:" + row.id + ":" + (row.snapshot || "")
    showList({ kind: "playlist", id: row.id, uri: row.uri, title: row.title, image: row.image },
      key, row.snapshot ? -1 : libraryTtlMs, function(done) {
        root.fetchPaged("/playlists/" + row.id + "/items?limit=50&additional_types=episode", "track",
          function(status, rows, payload) {
            // Older API surface for apps that still see /tracks only.
            if (status === 404) {
              root.fetchPaged("/playlists/" + row.id + "/tracks?limit=50&additional_types=episode", "track", done)
              return
            }
            done(status, rows, payload)
          })
      }, "This playlist")
  }

  function openLiked() {
    showList({ kind: "liked", id: "liked", title: "Liked Songs" }, "liked", libraryTtlMs, function(done) {
      root.fetchPaged("/me/tracks?limit=50", "track", done)
    }, "Liked Songs")
  }

  function openRecent() {
    showList({ kind: "recent", id: "recent", title: "Recently played" }, "recent", recentTtlMs, function(done) {
      root.api("GET", "/me/player/recently-played?limit=50", null, function(status, payload) {
        var rows = status === 200 && payload ? Spotify.normalizeList(payload.items, "track") : []
        var seen = {}
        rows = rows.filter(function(r) { if (seen[r.uri]) return false; seen[r.uri] = true; return true })
        done(status, rows, payload)
      })
    }, "Recently played")
  }

  // Show cached rows immediately (even stale ones), then refresh if needed.
  function showList(header, key, ttl, fetcher, label) {
    var list = Object.assign({ rows: [] }, header)
    var stale = staleEntry(key)
    if (stale) list.rows = stale
    openList = list
    openListError = ""
    if (cacheEntry(key, ttl)) {
      openListLoading = false
      return
    }
    openListLoading = true
    fetcher(function(status, rows, payload) {
      if (!root.openList || root.openList.kind !== header.kind || root.openList.id !== header.id) return
      root.openListLoading = false
      if (status === 200) {
        root.remember(key, rows)
        root.openList = Object.assign({}, root.openList, { rows: rows })
      } else {
        root.openListError = Spotify.quotaMessage(status, payload, label)
      }
    })
  }

  function closeList() {
    openList = null
    openListError = ""
    openListLoading = false
  }

  function loadQueue() {
    queueLoading = true
    queueError = ""
    api("GET", "/me/player/queue", null, function(status, payload) {
      root.queueLoading = false
      if (status === 200 && payload) root.queueRows = Spotify.normalizeList(payload.queue)
      else if (status === 204) root.queueRows = []
      else root.queueError = Spotify.quotaMessage(status, payload, "The queue")
    })
  }

  // Play a row. Albums, artists, and playlists play as their own context; a
  // song plays inside `context` (a playlist uri, or a list of uris for Liked
  // Songs / Recently played) so playback continues through that list.
  function playRow(row, context) {
    if (!row) return
    var body
    if (row.kind === "album" || row.kind === "artist" || row.kind === "playlist") {
      body = { context_uri: row.uri }
    } else if (context && context.uri) {
      body = { context_uri: context.uri, offset: { uri: row.uri } }
    } else if (context && context.uris) {
      var index = Math.max(0, context.uris.indexOf(row.uri))
      body = { uris: context.uris.slice(index, index + 100) }
    } else {
      body = { uris: [row.uri] }
    }
    startPlayback(body)
  }

  function playOpenList(shuffled) {
    var list = openList
    if (!list) return
    var body = list.kind === "playlist"
      ? { context_uri: list.uri }
      : { uris: list.rows.slice(0, 100).map(function(r) { return r.uri }) }
    if (!body.context_uri && body.uris.length === 0) return
    startPlayback(body, shuffled)
  }

  function queueRow(row) {
    if (!row || !row.uri) return
    api("POST", "/me/player/queue?uri=" + encodeURIComponent(row.uri), null, function(status, payload) {
      if (!Spotify.isSuccess(status)) root.lastError = Spotify.errorMessage(status, payload)
      else {
        root.lastError = ""
        root.flash("Added to queue: " + row.title)
      }
    })
  }

  // Start playback on the active device, or on this computer when nothing
  // is active yet (or the active device has gone away).
  function startPlayback(body, shuffled) {
    lastError = ""
    function onLocal() {
      root.withLocalDevice(function(id) {
        playOn(id, false)
      })
    }
    function playOn(id, allowFallback) {
      var target = "device_id=" + encodeURIComponent(id)
      root.api("PUT", "/me/player/play?" + target, body, function(status, payload) {
        if (status === 404 && allowFallback) {
          onLocal()
          return
        }
        if (!Spotify.isSuccess(status)) {
          root.lastError = Spotify.errorMessage(status, payload)
          return
        }
        // The receiver must be active before it can accept shuffle. Always
        // target the same device, and wait for playback to succeed first.
        if (shuffled !== undefined) {
          root.api("PUT", "/me/player/shuffle?state=" + shuffled + "&" + target, null,
            function(shuffleStatus, shufflePayload) {
              if (Spotify.isSuccess(shuffleStatus)) root.shuffle = shuffled
              else root.lastError = Spotify.errorMessage(shuffleStatus, shufflePayload)
              settlePoll.restart()
            })
        } else {
          settlePoll.restart()
        }
      })
    }
    if (!deviceId) {
      onLocal()
      return
    }
    playOn(deviceId, true)
  }

  function restoreLibrary(text) {
    var data = null
    try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
    if (!data || data.version !== 2 || !cacheKey || data.cacheKey !== cacheKey || !data.entries) return
    browseCache = Object.assign({}, data.entries, browseCache)
  }

  function saveLibrary() {
    var entries = {}
    var playlistKeys = []
    for (var key in browseCache) {
      if (key.indexOf("search:") === 0) continue
      if (key.indexOf("playlist:") === 0) playlistKeys.push(key)
      else entries[key] = browseCache[key]
    }
    // Keep the 30 most recently fetched playlists' contents.
    playlistKeys.sort(function(a, b) { return browseCache[b].t - browseCache[a].t })
    for (var i = 0; i < Math.min(30, playlistKeys.length); i++) entries[playlistKeys[i]] = browseCache[playlistKeys[i]]
    libraryFile.setText(JSON.stringify({ version: 2, cacheKey: cacheKey, entries: entries }))
  }

  Timer {
    id: noticeTimer
    interval: 2500
    onTriggered: root.notice = ""
  }

  Timer {
    id: saveLibraryTimer
    interval: 3000
    onTriggered: root.saveLibrary()
  }
  property alias saveLibrarySoon: saveLibraryTimer

  FileView {
    id: libraryFile
    path: root.cacheDir + "/library.json"
    printErrors: false
    onLoaded: root.restoreLibrary(text())
  }

  // ---- Internals

  function rateLimitedRoutes() {
    var result = {}
    for (var route in backoffUntil) {
      var seconds = Math.round((backoffUntil[route] - Date.now()) / 1000)
      if (seconds > 0) result[route] = seconds
    }
    return result
  }

  onIsPlayingChanged: saveCacheSoon.restart()

  function clearPlayback() {
    hasTrack = false
    isPlaying = false
    trackUri = ""
    trackUrl = ""
    title = ""
    artist = ""
    album = ""
    artUrl = ""
    durationMs = 0
    progressMs = 0
    deviceId = ""
    deviceName = ""
    supportsVolume = false
    volume = -1
    likedKnown = false
  }

  function applyPlayer(payload) {
    var state = Spotify.parsePlayer(payload)
    if (!state.hasTrack) {
      clearPlayback()
      return
    }
    var changedTrack = state.uri !== trackUri
    hasTrack = true
    isPlaying = state.isPlaying
    itemType = state.type
    trackUri = state.uri
    trackUrl = state.url
    title = state.title
    artist = state.artist
    album = state.album
    artUrl = state.artUrl
    durationMs = state.durationMs
    progressMs = state.progressMs
    progressStamp = Date.now()
    now = progressStamp
    shuffle = state.shuffle
    repeatState = state.repeatState
    deviceId = state.deviceId
    deviceName = state.deviceName
    deviceType = state.deviceType
    supportsVolume = state.supportsVolume
    if (!volumeDebounce.running) volume = state.volume
    disallows = state.disallows
    if (changedTrack) {
      checkLiked()
      saveCacheSoon.restart()
    }
    // Poll right as the track ends so the next song shows up immediately,
    // which lets the regular poll run at a relaxed pace.
    if (isPlaying && durationMs > 0) {
      trackEndPoll.interval = Math.max(500, durationMs - progressMs + 400)
      trackEndPoll.restart()
    } else {
      trackEndPoll.stop()
    }
  }

  function applyOptimistic(fields) {
    if (fields.progressMs !== undefined) {
      progressMs = fields.progressMs
      progressStamp = Date.now()
      now = progressStamp
    }
    if (fields.isPlaying !== undefined) {
      progressMs = position
      progressStamp = Date.now()
      now = progressStamp
      isPlaying = fields.isPlaying
    }
  }

  function checkLiked() {
    likedKnown = false
    liked = false
    if (!trackUri) return
    var uri = trackUri
    var cached = likedCache[uri]
    if (cached && Date.now() - cached.t < likedTtlMs) {
      liked = cached.v
      likedKnown = true
      return
    }
    api("GET", "/me/library/contains?uris=" + encodeURIComponent(uri), null, function(status, payload) {
      if (status !== 200 || !Array.isArray(payload)) return
      root.rememberLiked(uri, payload[0] === true)
      if (uri !== root.trackUri) return
      root.liked = payload[0] === true
      root.likedKnown = true
    })
  }

  function rememberLiked(uri, value) {
    var next = Object.assign({}, likedCache)
    next[uri] = { v: value, t: Date.now() }
    likedCache = next
    saveCacheSoon.restart()
  }

  function restoreCache(text) {
    var data = null
    try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
    if (!data || data.version !== 2 || !cacheKey || data.cacheKey !== cacheKey) return

    if (data.liked && typeof data.liked === "object") likedCache = data.liked

    var limits = {}
    for (var route in (data.backoffUntil || {})) {
      if (data.backoffUntil[route] > Date.now()) limits[route] = data.backoffUntil[route]
    }
    backoffUntil = limits

    // Shown paused until the first poll replaces (or clears) it.
    var last = data.lastTrack
    if (last && last.uri && !hasTrack && lastPollAt === 0) {
      hasTrack = true
      isPlaying = false
      trackUri = last.uri
      trackUrl = last.url || ""
      title = last.title || ""
      artist = last.artist || ""
      album = last.album || ""
      artUrl = last.artUrl || ""
      durationMs = last.durationMs || 0
      progressMs = last.progressMs || 0
      deviceName = last.deviceName || ""
      itemType = last.type || "track"
      checkLiked()
    }
  }

  function saveCache() {
    // Keep only the most recently checked tracks.
    var uris = Object.keys(likedCache)
    var liked = likedCache
    if (uris.length > likedCacheMax) {
      uris.sort(function(a, b) { return likedCache[b].t - likedCache[a].t })
      liked = {}
      for (var i = 0; i < likedCacheMax; i++) liked[uris[i]] = likedCache[uris[i]]
      likedCache = liked
    }
    var limits = {}
    for (var route in backoffUntil) {
      if (backoffUntil[route] > Date.now()) limits[route] = backoffUntil[route]
    }
    cacheFile.setText(JSON.stringify({
      version: 2,
      cacheKey: cacheKey,
      liked: liked,
      backoffUntil: limits,
      lastTrack: hasTrack ? {
        uri: trackUri, url: trackUrl, title: title, artist: artist, album: album,
        artUrl: artUrl, durationMs: durationMs, progressMs: position,
        deviceName: deviceName, type: itemType
      } : null
    }))
  }

  // A player command, followed by a quick re-poll so the bar reflects what
  // Spotify actually did rather than what we guessed.
  function command(method, path, body) {
    api(method, path, body || null, function(status, payload) {
      if (!Spotify.isSuccess(status)) root.lastError = Spotify.errorMessage(status, payload)
      else root.lastError = ""
      settlePoll.restart()
    })
  }

  function api(method, path, body, callback, retried, forceRefresh) {
    var generation = sessionGeneration
    var route = method + " " + path.split("?")[0]
    if (Date.now() < (backoffUntil[route] || 0)) {
      if (callback) callback(429, null)
      return
    }
    withToken(function(token) {
      if (generation !== root.sessionGeneration) return
      if (!token) {
        if (callback) callback(0, null)
        return
      }
      var xhr = new XMLHttpRequest()
      xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (generation !== root.sessionGeneration || !root.authEnabled) return
        var payload = null
        if (xhr.responseText) {
          try { payload = JSON.parse(xhr.responseText) } catch (e) { payload = null }
        }
        if (xhr.status === 401 && !retried) {
          // Another request may already have refreshed this rejected token.
          root.api(method, path, body, callback, true, !root.accessToken || root.accessToken === token)
          return
        }
        if (xhr.status === 429) {
          var retryAfter = Number(xhr.getResponseHeader("Retry-After")) || 5
          var limits = Object.assign({}, root.backoffUntil)
          limits[route] = Date.now() + retryAfter * 1000
          root.backoffUntil = limits
          root.saveCacheSoon.restart()
        }
        if (callback) callback(xhr.status, payload)
      }
      xhr.open(method, Spotify.API_BASE + path)
      xhr.setRequestHeader("Authorization", "Bearer " + token)
      if (body) {
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(JSON.stringify(body))
      } else {
        xhr.send()
      }
    }, forceRefresh)
  }

  function withToken(callback, forceRefresh) {
    if (!authEnabled) {
      callback("")
      return
    }
    if (forceRefresh) {
      accessToken = ""
      tokenExpiresAt = 0
      forceTokenRefresh = true
    }
    if (!forceTokenRefresh && accessToken && tokenExpiresAt - Date.now() > 60000) {
      callback(accessToken)
      return
    }
    var waiters = tokenWaiters.slice()
    waiters.push(callback)
    tokenWaiters = waiters
    startToken()
  }

  function startToken() {
    if (tokenBusy || !authEnabled || tokenWaiters.length === 0) return
    tokenProcess.generation = sessionGeneration
    tokenProcess.forced = forceTokenRefresh
    tokenProcess.command = forceTokenRefresh ? [authHelper, "token", "--force-refresh"] : [authHelper, "token"]
    tokenBusy = true
    tokenProcess.running = true
  }

  function finishToken(output, exitCode, generation, forced) {
    tokenBusy = false
    if (generation !== sessionGeneration || !authEnabled) {
      completeLogout()
      startToken()
      return
    }
    // A 401 may arrive while an ordinary disk-token lookup is in flight.
    // Hold its waiters until a forced refresh has actually completed.
    if (forceTokenRefresh && !forced) {
      startToken()
      return
    }
    forceTokenRefresh = false
    var result = {}
    try { result = JSON.parse(String(output || "").trim() || "{}") } catch (e) { result = {} }
    if (exitCode === 0 && result.access_token) {
      accessToken = result.access_token
      tokenExpiresAt = Number(result.expires_at) * 1000
      var nextKey = String(result.cache_key || "")
      if (nextKey !== cacheKey) {
        if (cacheKey) {
          // Also handle an account change made through the CLI helper.
          sessionGeneration++
          tokenWaiters = []
          loggedIn = false
        }
        resetAccountState()
        cacheKey = nextKey
        restoreLibrary(libraryFile.text())
        restoreCache(cacheFile.text())
      }
      grantedScope = String(result.scope || "")
      wantedScope = String(result.wanted_scope || "")
      loggedIn = true
    } else {
      accessToken = ""
      tokenExpiresAt = 0
      if (exitCode === 2) {
        authEnabled = false
        resetSession()
      } else if (result.error) {
        lastError = "Token refresh failed: " + result.error
      }
    }
    authChecked = true
    var waiters = tokenWaiters
    tokenWaiters = []
    for (var i = 0; i < waiters.length; i++) waiters[i](accessToken)
  }

  Process {
    id: tokenProcess
    property int generation: 0
    property bool forced: false
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    onExited: function(exitCode) { root.finishToken(tokenOut.text, exitCode, generation, forced) }
  }

  Process {
    id: loginProcess
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.loginBusy = false
      root.loggingIn = false
      if (root.loggingOut) {
        root.completeLogout()
        return
      }
      if (root.loginRestart) {
        root.loginRestart = false
        root.login()
        return
      }
      if (root.loginCancelled) {
        root.loginCancelled = false
        return
      }
      var result = {}
      try { result = JSON.parse(String(loginOut.text || "").trim() || "{}") } catch (e) { result = {} }
      if (exitCode !== 0) {
        root.lastError = "Sign-in failed: " + (result.error || "exit " + exitCode)
        return
      }
      root.resetSession()
      root.authEnabled = true
      root.withToken(function() {
        root.poll()
        root.refreshDevices()
      })
    }
  }

  Process {
    id: logoutProcess
    command: [root.authHelper, "logout"]
    onExited: function(exitCode) {
      root.loggingOut = false
      if (exitCode !== 0) root.lastError = "Could not remove the saved Spotify token. Try Disconnect again."
      if (root.loginAfterLogout) {
        root.loginAfterLogout = false
        root.login()
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.isPlaying ? Math.max(1000, root.activePollMs) : Math.max(2000, root.idlePollMs)
    running: root.loggedIn
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Process {
    id: localPlayerStarter
    command: ["systemctl", "--user", "start", "omafy-player.service"]
  }

  Timer {
    id: playAfterTransfer
    interval: 800
    onTriggered: {
      if (!root.pendingPlayDevice) return
      root.command("PUT", "/me/player/play?device_id=" + encodeURIComponent(root.pendingPlayDevice))
      root.pendingPlayDevice = ""
    }
  }

  Component {
    id: delayComponent
    Timer {}
  }

  Timer {
    id: trackEndPoll
    onTriggered: root.poll()
  }

  property alias saveCacheSoon: saveCacheTimer
  Timer {
    id: saveCacheTimer
    interval: 2000
    onTriggered: root.saveCache()
  }

  Process {
    id: cacheDirMaker
    command: ["mkdir", "-p", root.cacheDir]
    running: true
  }

  FileView {
    id: cacheFile
    path: root.cacheDir + "/state.json"
    printErrors: false
    onLoaded: root.restoreCache(text())
  }

  Timer {
    id: settlePoll
    interval: 350
    onTriggered: root.poll()
  }

  Timer {
    interval: 500
    running: root.isPlaying
    repeat: true
    onTriggered: root.now = Date.now()
  }

  Timer {
    id: volumeDebounce
    interval: 250
    onTriggered: {
      if (root.volumeTarget < 0) return
      root.command("PUT", "/me/player/volume?volume_percent=" + root.volumeTarget)
      root.volumeTarget = -1
    }
  }

  // Keybinding-friendly controls: `omarchy-shell omafy next`, etc.
  IpcHandler {
    target: "omafy"
    function playPause(): void { root.playPause() }
    function playHere(): void { root.playHere() }
    function search(query: string): void { root.search(query) }
    function loadLibrary(): void { root.loadPlaylists(true); root.loadQueue() }
    function browse(): string {
      return JSON.stringify({
        query: root.searchQuery,
        searching: root.searchLoading,
        searchError: root.searchError,
        sections: root.searchSections.map(function(s) { return s.title + ": " + s.rows.length }),
        firstSong: root.searchSections.length && root.searchSections[0].rows.length ? root.searchSections[0].rows[0].title : "",
        playlists: root.playlists.length,
        playlistsError: root.playlistsError,
        queue: root.queueRows.length,
        queueError: root.queueError,
        needsReconnect: root.needsReconnect,
        cachedKeys: Object.keys(root.browseCache).length
      })
    }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function like(): void { root.toggleLike() }
    function volumeUp(): void { root.nudgeVolume(5) }
    function volumeDown(): void { root.nudgeVolume(-5) }
    function login(): void { root.login() }
    function status(): string {
      return JSON.stringify({
        loggedIn: root.loggedIn,
        playing: root.isPlaying,
        title: root.title,
        artist: root.artist,
        device: root.deviceName,
        error: root.lastError,
        polling: pollTimer.running,
        pollMs: pollTimer.interval,
        rateLimited: root.rateLimitedRoutes(),
        lastPollStatus: root.lastPollStatus,
        lastPollAgeSeconds: root.lastPollAt ? Math.round((Date.now() - root.lastPollAt) / 1000) : -1
      })
    }
  }

  // Probe the stored token once so the bar knows whether to offer sign-in.
  Component.onCompleted: withToken(function() {})
}
