import QtQuick
import Quickshell
import qs.Commons
import qs.Services.Display
import qs.Widgets

// Proportional monitor arrangement. Tiles are draggable in layout space and
// snap to each other's edges; nothing is applied until the page says so.
Item {
  id: root

  property ListModel draftModel
  property string selectedName: ""
  property bool snapToEdges: true
  property int revision: 0

  readonly property real padding: Style.marginL
  readonly property real minTileWidth: 40 * Style.uiScaleRatio
  readonly property real minTileHeight: 30 * Style.uiScaleRatio

  signal selectRequested(string name)
  signal positionRequested(string name, int x, int y)

  property bool dragging: false
  property var frozenBounds: ({
                               "minX": 0,
                               "minY": 0,
                               "maxX": 1600,
                               "maxY": 1000
                             })

  property var bounds: computeBounds()
  readonly property var activeBounds: dragging ? frozenBounds : bounds

  function computeBounds() {
    var minX = 0;
    var minY = 0;
    var maxX = 0;
    var maxY = 0;
    var found = false;

    for (var i = 0; i < draftModel.count; i++) {
      var o = draftModel.get(i);
      var size = DisplayService.logicalSize(o);
      var x2 = o.x + size.footprintWidth;
      var y2 = o.y + size.footprintHeight;
      if (!found) {
        minX = o.x;
        minY = o.y;
        maxX = x2;
        maxY = y2;
        found = true;
      } else {
        minX = Math.min(minX, o.x);
        minY = Math.min(minY, o.y);
        maxX = Math.max(maxX, x2);
        maxY = Math.max(maxY, y2);
      }
    }

    if (!found)
      return {
        "minX": 0,
        "minY": 0,
        "maxX": 1600,
        "maxY": 1000
      };

    return {
      "minX": minX,
      "minY": minY,
      "maxX": maxX,
      "maxY": maxY
    };
  }

  readonly property real fit: {
    var b = activeBounds;
    var availableWidth = Math.max(1, width - padding * 2);
    var availableHeight = Math.max(1, height - padding * 2);
    var scaleX = availableWidth / Math.max(1, b.maxX - b.minX);
    var scaleY = availableHeight / Math.max(1, b.maxY - b.minY);
    return Math.max(0.02, Math.min(scaleX, scaleY));
  }

  readonly property real originX: {
    var b = activeBounds;
    var availableWidth = Math.max(1, width - padding * 2);
    return padding + (availableWidth - (b.maxX - b.minX) * fit) / 2;
  }

  readonly property real originY: {
    var b = activeBounds;
    var availableHeight = Math.max(1, height - padding * 2);
    return padding + (availableHeight - (b.maxY - b.minY) * fit) / 2;
  }

  function mapX(layoutX) {
    return originX + (layoutX - activeBounds.minX) * fit;
  }

  function mapY(layoutY) {
    return originY + (layoutY - activeBounds.minY) * fit;
  }

  function canvasToLayoutX(canvasX) {
    return activeBounds.minX + (canvasX - originX) / fit;
  }

  function canvasToLayoutY(canvasY) {
    return activeBounds.minY + (canvasY - originY) / fit;
  }

  function beginDrag() {
    frozenBounds = bounds;
    dragging = true;
  }

  function endDrag() {
    dragging = false;
  }

  function sizeOf(name) {
    for (var i = 0; i < draftModel.count; i++) {
      var o = draftModel.get(i);
      if (o.name === name)
        return DisplayService.logicalSize(o);
    }
    return {
      "footprintWidth": 1600,
      "footprintHeight": 1000
    };
  }

  // Edge magnetism: snap the dragged tile's left/right/top/bottom edges to the
  // other tiles' edges, and to the layout origin.
  function snapPosition(name, layoutX, layoutY) {
    var threshold = 9 / Math.max(0.02, fit);
    var mine = sizeOf(name);
    var bestX = Math.round(layoutX);
    var bestY = Math.round(layoutY);
    var bestXDistance = threshold;
    var bestYDistance = threshold;

    function tryX(candidate) {
      var distance = Math.abs(layoutX - candidate);
      if (distance < bestXDistance) {
        bestXDistance = distance;
        bestX = Math.round(candidate);
      }
    }

    function tryY(candidate) {
      var distance = Math.abs(layoutY - candidate);
      if (distance < bestYDistance) {
        bestYDistance = distance;
        bestY = Math.round(candidate);
      }
    }

    tryX(0);
    tryY(0);

    for (var i = 0; i < draftModel.count; i++) {
      var o = draftModel.get(i);
      if (o.name === name || !o.enabled)
        continue;

      var other = DisplayService.logicalSize(o);
      var left = o.x;
      var right = o.x + other.footprintWidth;
      var top = o.y;
      var bottom = o.y + other.footprintHeight;

      tryX(left);
      tryX(right);
      tryX(left - mine.footprintWidth);
      tryX(right - mine.footprintWidth);

      tryY(top);
      tryY(bottom);
      tryY(top - mine.footprintHeight);
      tryY(bottom - mine.footprintHeight);
    }

    return {
      "x": bestX,
      "y": bestY
    };
  }

  clip: true

  onRevisionChanged: {
    if (!dragging)
      bounds = computeBounds();
  }

  Component.onCompleted: bounds = computeBounds()

  Rectangle {
    anchors.fill: parent
    radius: Style.radiusM
    color: Color.smartAlpha(Color.mSurface)
    border.width: Style.borderS
    border.color: Color.mOutline
  }

  NText {
    anchors.centerIn: parent
    visible: root.draftModel.count === 0
    text: I18n.tr("panels.display.monitors-none")
    pointSize: Style.fontSizeM
    color: Color.mOnSurfaceVariant
  }

  Repeater {
    model: root.draftModel

    delegate: Item {
      id: tile

      required property var model

      readonly property string outputName: model.name || ""
      readonly property bool selected: root.selectedName === outputName
      readonly property var size: DisplayService.logicalSize({
                                                              "width": model.width,
                                                              "height": model.height,
                                                              "scale": model.scale,
                                                              "transform": model.transform
                                                            })

      property bool dragging: false
      property real previewX: 0
      property real previewY: 0
      property int pendingX: 0
      property int pendingY: 0

      x: dragging ? previewX : root.mapX(model.x || 0)
      y: dragging ? previewY : root.mapY(model.y || 0)
      width: Math.max(root.minTileWidth, size.footprintWidth * root.fit)
      height: Math.max(root.minTileHeight, size.footprintHeight * root.fit)
      opacity: model.enabled ? 1.0 : 0.5
      z: selected ? 2 : 1

      Behavior on opacity {
        NumberAnimation {
          duration: Style.animationFast
        }
      }

      Rectangle {
        anchors.fill: parent
        radius: Style.iRadiusM
        color: tile.selected ? Qt.alpha(Color.mPrimary, 0.18) : Color.smartAlpha(Color.mSurfaceVariant)
        border.width: tile.selected ? Math.max(2, Style.borderM) : Style.borderS
        border.color: tile.selected ? Color.mPrimary : (model.focused ? Qt.alpha(Color.mPrimary, 0.6) : Color.mOutline)
      }

      Column {
        anchors.fill: parent
        anchors.margins: Math.max(6, Style.marginS)
        spacing: Style.marginXXS
        clip: true

        NText {
          width: parent.width
          text: tile.outputName
          pointSize: Style.fontSizeM
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
          elide: Text.ElideMiddle
        }

        NText {
          width: parent.width
          visible: tile.height > 52 * Style.uiScaleRatio
          text: {
            var scaleText = Number(model.scale) > 0 ? (Number(model.scale).toFixed(2).replace(/0+$/, "").replace(/\.$/, "") + "×") : "";
            return Math.round(model.width) + "×" + Math.round(model.height) + (scaleText !== "" ? "  " + scaleText : "");
          }
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
          elide: Text.ElideRight
        }

        NText {
          width: parent.width
          visible: !model.enabled && tile.height > 44 * Style.uiScaleRatio
          text: I18n.tr("common.disabled")
          pointSize: Style.fontSizeXS
          font.weight: Style.fontWeightBold
          color: Color.mError
        }
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

        property real grabOffsetX: 0
        property real grabOffsetY: 0
        property bool moved: false

        onPressed: function (mouse) {
          root.selectRequested(tile.outputName);
          var point = dragArea.mapToItem(root, mouse.x, mouse.y);
          grabOffsetX = point.x - tile.x;
          grabOffsetY = point.y - tile.y;
          tile.pendingX = Math.round(model.x || 0);
          tile.pendingY = Math.round(model.y || 0);
          tile.previewX = tile.x;
          tile.previewY = tile.y;
          tile.dragging = true;
          moved = false;
          root.beginDrag();
        }

        onPositionChanged: function (mouse) {
          if (!pressed)
            return;

          var point = dragArea.mapToItem(root, mouse.x, mouse.y);
          var canvasX = Math.max(0, Math.min(root.width - tile.width, point.x - grabOffsetX));
          var canvasY = Math.max(0, Math.min(root.height - tile.height, point.y - grabOffsetY));
          var layoutX = root.canvasToLayoutX(canvasX);
          var layoutY = root.canvasToLayoutY(canvasY);

          if (root.snapToEdges) {
            var snapped = root.snapPosition(tile.outputName, layoutX, layoutY);
            layoutX = snapped.x;
            layoutY = snapped.y;
          }

          tile.pendingX = Math.round(layoutX);
          tile.pendingY = Math.round(layoutY);
          tile.previewX = root.mapX(tile.pendingX);
          tile.previewY = root.mapY(tile.pendingY);
          moved = true;
        }

        onReleased: {
          tile.dragging = false;
          root.endDrag();
          if (moved)
            root.positionRequested(tile.outputName, tile.pendingX, tile.pendingY);
        }

        onCanceled: {
          tile.dragging = false;
          root.endDrag();
        }
      }
    }
  }
}
