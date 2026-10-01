import QtQuick
import qs.Commons

// Scrolling list of section headers ({ header: "Songs" }) and media rows.
ListView {
  id: list

  property var service: null
  property color foreground: Color.foreground
  property color muted: Color.muted
  property color accent: "#1ed760"
  property string fontFamily: Style.font.family
  property bool chevrons: false
  property bool clickable: true
  property bool allowQueue: true
  property string emptyText: ""

  signal rowActivated(var item)

  clip: true
  spacing: Style.space(2)
  boundsBehavior: Flickable.StopAtBounds
  reuseItems: true

  delegate: Item {
    id: entry
    required property var modelData
    readonly property bool isHeader: modelData.header !== undefined

    width: ListView.view.width
    height: isHeader ? headerText.implicitHeight + Style.space(12) : mediaRow.height

    Text {
      textFormat: Text.PlainText
      id: headerText
      visible: entry.isHeader
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(4)
      text: entry.isHeader ? entry.modelData.header : ""
      color: list.muted
      font.family: list.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MediaRow {
      id: mediaRow
      visible: !entry.isHeader
      width: parent.width
      item: entry.isHeader ? ({}) : entry.modelData
      foreground: list.foreground
      muted: list.muted
      accent: list.accent
      fontFamily: list.fontFamily
      clickable: list.clickable
      allowQueue: list.allowQueue
      chevron: list.chevrons
      current: !entry.isHeader && list.service && entry.modelData.uri === list.service.trackUri
      onActivated: list.rowActivated(entry.modelData)
      onQueued: if (list.service) list.service.queueRow(entry.modelData)
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    width: parent.width - Style.space(24)
    visible: list.count === 0 && list.emptyText !== ""
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    text: list.emptyText
    color: list.muted
    font.family: list.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
