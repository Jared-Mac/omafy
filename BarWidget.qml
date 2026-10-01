import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Spotify.js" as Spotify

// Spotify now-playing for the bar. Left click opens the player popup, middle
// click toggles playback, right click skips, and the wheel changes Spotify's
// own volume. All state lives in Service.qml.
Panel {
  id: root

  moduleName: "jaredm.omafy"
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("jaredm.omafy") : null
  readonly property bool loggedIn: service ? service.loggedIn : false
  readonly property bool hasTrack: service ? service.hasTrack : false
  readonly property bool playing: service ? service.isPlaying : false

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color popupForeground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Color.muted
  readonly property color spotifyGreen: "#1ed760"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool showArtist: setting("showArtist", true) === true
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property bool greenWhenPlaying: setting("greenWhenPlaying", true) === true
  readonly property real maxLabelWidth: Style.space(Number(setting("maxLabelWidth", 220)))

  readonly property string labelText: {
    if (!service || !service.authChecked) return ""
    if (!loggedIn) return "Connect Spotify"
    if (!hasTrack) return ""
    return service.title + (showArtist && service.artist ? "  ·  " + service.artist : "")
  }

  onServiceChanged: pushSettings()
  onSettingsChanged: pushSettings()

  function pushSettings() {
    if (!service) return
    var id = String(setting("clientId", "") || "").trim()
    service.clientId = /^[0-9a-fA-F]{32}$/.test(id) ? id : Spotify.DEFAULT_CLIENT_ID
    service.activePollMs = Number(setting("pollIntervalMs", 5000))
  }

  // ---- Popup tabs
  property string tab: "now"
  readonly property real browseHeight: Style.space(420)

  onOpenedChanged: if (opened) setTab(tab)

  function setTab(id) {
    tab = id
    if (!service) return
    if (id === "now") service.refreshDevices()
    else if (id === "library") service.loadPlaylists(false)
    else if (id === "queue") service.loadQueue()
    else if (id === "search") Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function flattenSections(sections) {
    var entries = []
    for (var i = 0; i < sections.length; i++) {
      entries.push({ header: sections[i].title })
      entries = entries.concat(sections[i].rows)
    }
    return entries
  }

  function libraryEntries(playlists, loading) {
    var entries = [
      { kind: "liked", id: "liked", uri: "omafy:liked", title: "Liked Songs", subtitle: "Your saved songs",
        glyph: "󰋑", glyphColor: spotifyGreen },
      { kind: "recent", id: "recent", uri: "omafy:recent", title: "Recently played", subtitle: "Last 50 songs",
        glyph: "󰋚" },
      { header: loading && playlists.length === 0 ? "Playlists · loading…" : "Playlists" }
    ]
    return entries.concat(playlists)
  }

  function queueEntries(rows) {
    return rows.length > 0 ? [{ header: "Next up" }].concat(rows) : []
  }

  function openListContext() {
    var list = service ? service.openList : null
    if (!list) return null
    if (list.kind === "playlist") return { uri: list.uri }
    return { uris: list.rows.map(function(r) { return r.uri }) }
  }

  Timer {
    id: searchDebounce
    interval: 350
    onTriggered: if (root.service) root.service.search(searchField.text)
  }

  visible: !(hideWhenIdle && loggedIn && !hasTrack)
  implicitWidth: visible ? barButton.implicitWidth : 0
  implicitHeight: barButton.implicitHeight

  WidgetButton {
    id: barButton

    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: barVisual.implicitWidth + Style.space(16)
    fixedHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal
    tooltipText: !root.loggedIn ? "Click to connect Spotify"
      : root.hasTrack ? root.service.title + " — " + root.service.artist
        + (root.service.localIsActive ? "\non this computer"
          : root.service.deviceName ? "\non " + root.service.deviceName : "")
      : "Spotify · middle-click to play here"

    onPressed: function(button) {
      if (!root.service) return
      if (button === Qt.MiddleButton) root.service.playPause()
      else if (button === Qt.RightButton) root.service.next()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (root.service) root.service.nudgeVolume(delta > 0 ? 5 : -5)
    }

    Row {
      id: barVisual
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        text: barButton.vertical || root.labelText === "" ? "󰓇" : ""
        color: root.playing && root.greenWhenPlaying ? root.spotifyGreen
          : root.hasTrack ? root.foreground : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
        Behavior on color { ColorAnimation { duration: 160 } }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !barButton.vertical && root.labelText !== ""
        width: Math.min(root.maxLabelWidth, implicitWidth)
        text: root.labelText
        elide: Text.ElideRight
        color: root.playing || !root.loggedIn ? root.foreground : Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(720))

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ---- Signed out
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.loggedIn

          Text {
            textFormat: Text.PlainText
            text: "Spotify"
            color: root.popupForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: root.service && root.service.loggingIn
              ? "Finish signing in in your browser…"
              : "Connect your Spotify account to control playback from the bar."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: root.service && root.service.loggingIn ? "Try again" : "Connect Spotify"
              iconText: ""
              foreground: root.popupForeground
              enabled: !!root.service
              onClicked: root.service.login()
            }

            Button {
              visible: root.service && root.service.loggingIn
              text: "Cancel"
              foreground: root.popupForeground
              onClicked: root.service.cancelLogin()
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: "Your Spotify app must list this Redirect URI exactly:"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextEdit {
            width: parent.width
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAnywhere
            text: root.service ? root.service.redirectUri : ""
            color: root.popupForeground
            selectionColor: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Tabs
        Row {
          visible: root.loggedIn
          spacing: Style.space(4)

          Repeater {
            model: [
              { id: "now", icon: "󰎆", label: "Now" },
              { id: "search", icon: "󰍉", label: "Search" },
              { id: "library", icon: "󰲸", label: "Library" },
              { id: "queue", icon: "󰲹", label: "Queue" }
            ]

            Button {
              required property var modelData
              text: modelData.label
              iconText: modelData.icon
              selected: root.tab === modelData.id
              foreground: root.popupForeground
              fontSize: Style.font.bodySmall
              onClicked: root.setTab(modelData.id)
            }
          }
        }

        Column {
          id: nowTab
          width: parent.width
          spacing: Style.space(10)
          visible: root.loggedIn && root.tab === "now"
          // ---- Now playing
          Row {
            width: parent.width
            spacing: Style.space(12)
            visible: root.loggedIn

            BorderSurface {
              id: artFrame
              width: Style.space(84)
              height: width
              radius: Style.spacing.labelGap
              color: Style.normalFillFor(root.popupForeground, Color.accent)
              borderSpec: Border.controlSpec("normal", root.popupForeground, Color.accent)

              Image {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 256
                sourceSize.height: 256
                source: root.service && root.service.artUrl ? root.service.artUrl : ""
                visible: status === Image.Ready
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: !root.service || !root.service.artUrl
                text: "󰝚"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: root.hasTrack ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (root.service) root.service.openInSpotify()
              }
            }

            Column {
              width: parent.width - artFrame.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Item {
                width: parent.width
                height: titleText.implicitHeight

                Text {
                  id: titleText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  text: root.hasTrack ? root.service.title : "Nothing playing"
                  color: root.popupForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
              }

              Text {
                width: parent.width
                visible: text !== ""
                text: root.hasTrack ? root.service.artist : "Resume your last session here, or pick a device below."
                color: Qt.darker(root.popupForeground, 1.25)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: root.hasTrack ? Text.ElideRight : Text.ElideNone
                wrapMode: root.hasTrack ? Text.NoWrap : Text.Wrap
                textFormat: Text.PlainText
              }

              Text {
                width: parent.width
                visible: root.hasTrack && text !== ""
                text: root.hasTrack ? root.service.album : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }
          }

          Button {
            visible: root.loggedIn && !root.hasTrack
            text: "Play on this computer"
            iconText: "󰐊"
            foreground: root.spotifyGreen
            onClicked: root.service.playHere()
          }

          // ---- Progress
          Column {
            width: parent.width
            spacing: 0
            visible: root.loggedIn && root.hasTrack

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0
              maximum: Math.max(1, root.service ? root.service.durationMs : 1)
              step: 1000
              value: root.service ? root.service.position : 0
              onReleased: function(value) { root.service.seek(value) }
            }

            Item {
              width: parent.width
              height: elapsed.implicitHeight

              Text {
                textFormat: Text.PlainText
                id: elapsed
                text: Spotify.formatTime(root.service ? root.service.position : 0)
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: Spotify.formatTime(root.service ? root.service.durationMs : 0)
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Transport
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            visible: root.loggedIn && root.hasTrack

            Button {
              iconText: "󰒟"
              tooltipText: "Shuffle"
              foreground: root.service && root.service.shuffle ? root.spotifyGreen : root.popupForeground
              selected: root.service ? root.service.shuffle : false
              onClicked: root.service.toggleShuffle()
            }

            Button {
              iconText: "󰒮"
              tooltipText: "Previous"
              foreground: root.popupForeground
              onClicked: root.service.previous()
            }

            Button {
              iconText: root.playing ? "󰏤" : "󰐊"
              tooltipText: root.playing ? "Pause" : "Play"
              foreground: root.popupForeground
              iconSize: Style.font.iconLarge
              horizontalPadding: Style.spacing.panelGap
              onClicked: root.service.playPause()
            }

            Button {
              iconText: "󰒭"
              tooltipText: "Next"
              foreground: root.popupForeground
              onClicked: root.service.next()
            }

            Button {
              iconText: Spotify.repeatGlyph(root.service ? root.service.repeatState : "off")
              tooltipText: root.service && root.service.repeatState === "track" ? "Repeat track"
                : root.service && root.service.repeatState === "context" ? "Repeat" : "Repeat off"
              foreground: root.service && root.service.repeatState !== "off" ? root.spotifyGreen : root.popupForeground
              selected: root.service ? root.service.repeatState !== "off" : false
              onClicked: root.service.cycleRepeat()
            }

            Button {
              iconText: root.service && root.service.liked ? "󰋑" : "󰋕"
              tooltipText: root.service && root.service.liked ? "Remove from Liked Songs" : "Add to Liked Songs"
              foreground: root.service && root.service.liked ? root.spotifyGreen : root.popupForeground
              selected: root.service ? root.service.liked : false
              onClicked: root.service.toggleLike()
            }
          }

          // ---- Volume
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.loggedIn && root.hasTrack && root.service.supportsVolume

            Text {
              textFormat: Text.PlainText
              id: volumeGlyph
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.volume === 0 ? "󰝟" : "󰕾"
              color: root.popupForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            PanelSlider {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - volumeGlyph.width - volumeText.width - parent.spacing * 2
              bar: root.bar
              minimum: 0
              maximum: 100
              step: 1
              integer: true
              value: root.service ? Math.max(0, root.service.volume) : 0
              onMoved: function(value) { root.service.setVolume(value) }
            }

            Text {
              textFormat: Text.PlainText
              id: volumeText
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(30)
              horizontalAlignment: Text.AlignRight
              text: root.service ? Math.max(0, root.service.volume) + "%" : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }


          // ---- Devices
          PanelSeparator {
            visible: root.loggedIn
            foreground: root.popupForeground
          }

          Text {
            textFormat: Text.PlainText
            visible: root.loggedIn
            text: "Devices"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            visible: root.loggedIn && root.service && root.service.devices.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: "No devices found. Open Spotify somewhere to see it here."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            id: deviceList
            width: parent.width
            spacing: Style.space(2)
            visible: root.loggedIn

            Repeater {
              model: root.service ? root.service.devices : []

              Rectangle {
                id: deviceRow
                required property var modelData
                readonly property bool active: modelData.is_active === true

                width: deviceList.width
                height: Style.space(32)
                radius: Style.cornerRadius
                color: deviceMouse.containsMouse ? Style.hoverFillFor(root.popupForeground, Color.accent)
                  : active ? Style.selectedFillFor(root.popupForeground, Color.accent) : "transparent"

                Text {
                  textFormat: Text.PlainText
                  id: deviceGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Spotify.deviceGlyph(deviceRow.modelData.type)
                  color: deviceRow.active ? root.spotifyGreen : root.popupForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.left: deviceGlyph.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: deviceState.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: deviceRow.modelData.name === root.service.localDeviceName
                    ? "This computer"
                    : String(deviceRow.modelData.name || "Unknown device")
                  color: deviceRow.active ? root.spotifyGreen : root.popupForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: deviceRow.active
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }

                Text {
                  textFormat: Text.PlainText
                  id: deviceState
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: deviceRow.active ? (root.playing ? "playing" : "active") : ""
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: deviceMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: deviceRow.active ? Qt.ArrowCursor : Qt.PointingHandCursor
                  onClicked: if (!deviceRow.active) root.service.transferTo(deviceRow.modelData.id)
                }
              }
            }
          }

          Item {
            width: parent.width
            height: signOut.implicitHeight
            visible: root.loggedIn

            Text {
              textFormat: Text.PlainText
              id: signOut
              anchors.right: parent.right
              text: "Disconnect"
              color: signOutMouse.containsMouse ? root.popupForeground : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: signOutMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.service.logout()
              }
            }
          }
        }

        // ---- Search
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.loggedIn && root.tab === "search"

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Songs, artists, albums, playlists"
            foreground: root.popupForeground
            onTextChanged: searchDebounce.restart()
            onAccepted: {
              searchDebounce.stop()
              root.service.search(text)
            }
            Keys.onEscapePressed: root.close()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            wrapMode: Text.Wrap
            text: !root.service ? ""
              : root.service.searchLoading ? "Searching…"
              : root.service.searchError
            color: root.service && root.service.searchError ? Color.urgent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          BrowseList {
            width: parent.width
            height: root.browseHeight - searchField.height - Style.space(8)
            service: root.service
            foreground: root.popupForeground
            muted: root.muted
            accent: root.spotifyGreen
            fontFamily: root.fontFamily
            model: root.flattenSections(root.service ? root.service.searchSections : [])
            emptyText: root.service && root.service.searchQuery !== "" && !root.service.searchLoading
              && !root.service.searchError ? "No results." : ""
            onRowActivated: function(item) { root.service.playRow(item, null) }
          }
        }

        // ---- Library
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.loggedIn && root.tab === "library"

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.service && root.service.needsReconnect

            Text {
              textFormat: Text.PlainText
              width: parent.width - reconnectButton.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.Wrap
              text: "Reconnect once to allow playlists and recently played."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              id: reconnectButton
              text: root.service && root.service.loggingIn ? "Waiting…" : "Reconnect"
              foreground: root.spotifyGreen
              onClicked: root.service.login()
            }
          }

          // Library root: Liked Songs, Recently played, then playlists.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.service && !root.service.openList

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              wrapMode: Text.Wrap
              text: root.service ? root.service.playlistsError : ""
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            BrowseList {
              width: parent.width
              height: root.browseHeight - Style.space(root.service && root.service.needsReconnect ? 44 : 0)
              service: root.service
              foreground: root.popupForeground
              muted: root.muted
              accent: root.spotifyGreen
              fontFamily: root.fontFamily
              chevrons: true
              allowQueue: false
              model: root.libraryEntries(root.service ? root.service.playlists : [],
                root.service ? root.service.playlistsLoading : false)
              onRowActivated: function(item) {
                if (item.kind === "liked") root.service.openLiked()
                else if (item.kind === "recent") root.service.openRecent()
                else if (item.kind === "playlist") root.service.openPlaylist(item)
              }
            }
          }

          // An opened list: header with back / play / shuffle, then its songs.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.service && !!root.service.openList

            Row {
              id: listHeader
              width: parent.width
              spacing: Style.space(6)

              Button {
                id: backButton
                iconText: "󰁍"
                tooltipText: "Back"
                foreground: root.popupForeground
                onClicked: root.service.closeList()
              }

              Text {
                width: listHeader.width - backButton.width - playListButton.width - shuffleListButton.width - listHeader.spacing * 3
                anchors.verticalCenter: parent.verticalCenter
                text: root.service && root.service.openList ? root.service.openList.title : ""
                color: root.popupForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Button {
                id: playListButton
                iconText: "󰐊"
                tooltipText: "Play"
                foreground: root.spotifyGreen
                onClicked: root.service.playOpenList(false)
              }

              Button {
                id: shuffleListButton
                iconText: "󰒟"
                tooltipText: "Shuffle play"
                foreground: root.popupForeground
                onClicked: root.service.playOpenList(true)
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              wrapMode: Text.Wrap
              text: !root.service ? ""
                : root.service.openListError !== "" ? root.service.openListError
                : root.service.openListLoading ? "Loading…" : ""
              color: root.service && root.service.openListError ? Color.urgent : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            BrowseList {
              width: parent.width
              height: root.browseHeight - listHeader.height - Style.space(6)
              service: root.service
              foreground: root.popupForeground
              muted: root.muted
              accent: root.spotifyGreen
              fontFamily: root.fontFamily
              model: root.service && root.service.openList ? root.service.openList.rows : []
              onRowActivated: function(item) { root.service.playRow(item, root.openListContext()) }
            }
          }
        }

        // ---- Queue
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.loggedIn && root.tab === "queue"

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            wrapMode: Text.Wrap
            text: !root.service ? "" : root.service.queueError !== "" ? root.service.queueError
              : root.service.queueLoading && root.service.queueRows.length === 0 ? "Loading…" : ""
            color: root.service && root.service.queueError ? Color.urgent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          BrowseList {
            width: parent.width
            height: root.browseHeight
            service: root.service
            foreground: root.popupForeground
            muted: root.muted
            accent: root.spotifyGreen
            fontFamily: root.fontFamily
            clickable: false
            allowQueue: false
            model: root.queueEntries(root.service ? root.service.queueRows : [])
            emptyText: root.service && !root.service.queueLoading ? "Nothing queued." : ""
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.loggedIn && text !== ""
          wrapMode: Text.Wrap
          text: root.service ? root.service.notice : ""
          color: root.spotifyGreen
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.service && root.service.lastError !== ""
          wrapMode: Text.Wrap
          text: root.service ? root.service.lastError : ""
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
