import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.Keyboard
import qs.Widgets

Item {
  id: root

  property var item: null
  property bool selected: false

  signal selectRequested()
  signal activateRequested()
  signal deleteRequested()

  readonly property bool hovered: mouseArea.containsMouse
  readonly property color fg: selected ? Color.mOnSecondary : (hovered ? Color.mOnHover : Color.mOnSurface)
  readonly property color fgDim: selected ? Qt.alpha(Color.mOnSecondary, 0.75) : (hovered ? Qt.alpha(Color.mOnHover, 0.75) : Color.mOnSurfaceVariant)
  readonly property var imageMeta: item && item.isImage ? ClipboardService.parseImageMeta(item.preview) : null
  readonly property bool isColor: item && item.contentType === "color"
  readonly property string typeName: {
    if (!item)
      return "";
    if (item.isImage)
      return I18n.tr("clipboard.types.image");
    switch (item.contentType) {
    case "link":
      return I18n.tr("clipboard.types.link");
    case "file":
      return I18n.tr("clipboard.types.file");
    case "code":
      return I18n.tr("clipboard.types.code");
    case "color":
      return I18n.tr("clipboard.types.color");
    default:
      return I18n.tr("clipboard.types.text");
    }
  }
  readonly property string typeIcon: {
    if (!item)
      return "clipboard";
    if (item.isImage)
      return "photo";
    switch (item.contentType) {
    case "link":
      return "link";
    case "file":
      return "file";
    case "code":
      return "code";
    case "color":
      return "palette";
    default:
      return "clipboard";
    }
  }
  readonly property string previewText: {
    if (!item)
      return "";
    if (item.isImage) {
      var meta = imageMeta;
      return I18n.tr("clipboard.types.image") + (meta ? (" " + meta.w + "×" + meta.h) : "");
    }
    var text = String(item.preview || "").replace(/\s+/g, " ").trim();
    return text.length > 0 ? text : "—";
  }
  readonly property string metaText: {
    if (!item)
      return "";
    var parts = [typeName];
    if (imageMeta && item.isImage) {
      if (imageMeta.fmt)
        parts.push(imageMeta.fmt);
      if (imageMeta.size)
        parts.push(imageMeta.size);
    } else if (item.contentType === "color") {
      parts.push(String(item.preview || "").trim());
    }
    var firstSeen = ClipboardService.firstSeenById[item.id] || Time.timestamp;
    var relative = Time.formatRelativeTime(new Date(firstSeen * 1000));
    if (relative)
      parts.push(relative);
    return parts.join(" · ");
  }

  width: ListView.view ? ListView.view.width : 0
  height: Math.max(56 * Style.uiScaleRatio, content.implicitHeight + Style.marginM * 2)

  Rectangle {
    anchors.fill: parent
    radius: Style.radiusM
    color: root.selected ? Color.mSecondary : (root.hovered ? Color.mHover : "transparent")
    border.color: root.selected ? Color.mOutline : "transparent"
    border.width: Style.borderS

    Behavior on color {
      ColorAnimation {
        duration: Style.animationFast
      }
    }
  }

  // Behind the content so the delete button (which accepts clicks) wins.
  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    onClicked: root.selectRequested()
    onDoubleClicked: root.activateRequested()
  }

  RowLayout {
    id: content
    anchors.fill: parent
    anchors.leftMargin: Style.marginS
    anchors.rightMargin: Style.marginS
    anchors.topMargin: Style.marginM
    anchors.bottomMargin: Style.marginM
    spacing: Style.marginS
    z: 1

    Item {
      Layout.preferredWidth: 32 * Style.uiScaleRatio
      Layout.preferredHeight: 32 * Style.uiScaleRatio
      Layout.alignment: Qt.AlignVCenter

      Rectangle {
        visible: root.isColor
        anchors.centerIn: parent
        width: Style.baseWidgetSize * 0.62
        height: width
        radius: height / 2
        color: root.item && root.item.preview ? root.item.preview : "transparent"
        border.color: Color.mOutline
        border.width: Style.borderS
      }

      NIcon {
        visible: !root.isColor
        anchors.centerIn: parent
        icon: root.typeIcon
        pointSize: Style.fontSizeL
        color: root.fg
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.marginXXS

      NText {
        Layout.fillWidth: true
        text: root.previewText
        pointSize: Style.fontSizeM
        color: root.fg
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      NText {
        Layout.fillWidth: true
        text: root.metaText
        pointSize: Style.fontSizeXS
        color: root.fgDim
        elide: Text.ElideRight
      }
    }

    NIconButton {
      icon: "trash"
      tooltipText: I18n.tr("clipboard.delete")
      baseSize: Style.baseWidgetSize * 0.62
      visible: root.hovered || root.selected
      colorFg: root.fg
      colorBg: "transparent"
      colorBgHover: Color.mError
      colorFgHover: Color.mOnError
      colorBorder: "transparent"
      colorBorderHover: "transparent"
      onClicked: root.deleteRequested()
    }
  }
}
