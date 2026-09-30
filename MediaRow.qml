import QtQuick
import qs.Commons

// One row in the browse lists: thumbnail, title, subtitle, and (for songs) an
// add-to-queue button on hover. Rows use the compact shape from
// Spotify.normalize().
Rectangle {
  id: row

  property var item: ({})
  property color foreground: Color.foreground
  property color muted: Color.muted
  property color accent: "#1ed760"
  property string fontFamily: Style.font.family
  property bool current: false
  property bool chevron: false
  property bool clickable: true
  property bool allowQueue: true

  readonly property bool queueable: allowQueue && (item.kind === "track" || item.kind === "episode")

  signal activated()
  signal queued()

  height: Style.space(44)
  radius: Style.cornerRadius
  color: mouse.containsMouse && clickable ? Style.hoverFillFor(foreground, Color.accent) : "transparent"

  Rectangle {
    id: thumb
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(36)
    height: width
    radius: row.item.kind === "artist" ? width / 2 : Style.space(3)
    color: Style.normalFillFor(row.foreground, Color.accent)
    clip: true

    Image {
      id: art
      anchors.fill: parent
      source: row.item.image || ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      sourceSize.width: 96
      sourceSize.height: 96
      visible: status === Image.Ready
    }

    Text {
      anchors.centerIn: parent
      visible: art.status !== Image.Ready
      text: row.item.glyph || (row.item.kind === "artist" ? "󰀄" : row.item.kind === "playlist" ? "󰲸" : "󰝚")
      color: row.item.glyphColor || row.muted
      font.family: row.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  Column {
    anchors.left: thumb.right
    anchors.leftMargin: Style.space(10)
    anchors.right: trailing.left
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(1)

    Text {
      width: parent.width
      text: String(row.item.title || "")
      color: row.current ? row.accent : row.foreground
      font.family: row.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: row.current
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: String(row.item.subtitle || "")
      color: row.muted
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }

  Row {
    id: trailing
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Text {
      id: queueGlyph
      visible: row.queueable && mouse.containsMouse
      anchors.verticalCenter: parent.verticalCenter
      text: "󰐕"
      color: queueMouse.containsMouse ? row.accent : row.muted
      font.family: row.fontFamily
      font.pixelSize: Style.font.body

      MouseArea {
        id: queueMouse
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.queued()
      }
    }

    Text {
      visible: row.chevron
      anchors.verticalCenter: parent.verticalCenter
      text: "󰅂"
      color: row.muted
      font.family: row.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    z: -1
    hoverEnabled: true
    cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    // Middle click queues a song without playing it.
    onClicked: function(event) {
      if (event.button === Qt.MiddleButton && row.queueable) row.queued()
      else if (row.clickable) row.activated()
    }
  }
}
