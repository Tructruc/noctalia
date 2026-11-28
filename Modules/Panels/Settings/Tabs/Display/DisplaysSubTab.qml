import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.Display
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root

  spacing: Style.marginL
  Layout.fillWidth: true

  property ListModel draft: ListModel {}
  property string selectedName: ""
  property var selectedOutput: ({})
  property var layout: []
  property int draftRevision: 0
  property int pendingCount: 0
  property bool externalChanged: false
  property bool _initialized: false
  property string _liveSignature: ""

  readonly property bool dirty: pendingCount > 0
  readonly property bool available: DisplayService.available
  readonly property bool busy: DisplayService.applying
  readonly property var overlapPairs: {
    draftRevision; // re-evaluate when the draft changes
    return DisplayService.overlaps(layout);
  }
  readonly property string persistSnippet: DisplayService.persistsLua ? "require(\"monitors\")" : ("source = " + DisplayService.confPath)

  // ---------------------------------------------------------------------------
  // Draft helpers
  // ---------------------------------------------------------------------------
  function indexOfOutput(name) {
    for (var i = 0; i < draft.count; i++) {
      if (draft.get(i).name === name)
        return i;
    }
    return -1;
  }

  function publish() {
    var items = [];
    for (var i = 0; i < draft.count; i++)
      items.push(draft.get(i));
    layout = items;
  }

  function refreshSelected() {
    var index = indexOfOutput(selectedName);
    if (index < 0) {
      selectedOutput = ({});
      return;
    }

    var o = draft.get(index);
    var modes = [];
    try {
      modes = JSON.parse(o.modesJson || "[]");
    } catch (e) {
      modes = [];
    }

    selectedOutput = {
      "name": o.name,
      "description": o.description,
      "make": o.make,
      "modelName": o.modelName,
      "enabled": o.enabled,
      "focused": o.focused,
      "width": o.width,
      "height": o.height,
      "refresh": o.refresh,
      "scale": o.scale,
      "transform": o.transform,
      "vrr": o.vrr,
      "x": o.x,
      "y": o.y,
      "mirror": o.mirror,
      "bitdepth": o.bitdepth,
      "cm": o.cm,
      "sdrBrightness": o.sdrBrightness,
      "sdrSaturation": o.sdrSaturation,
      "modes": modes,
      "modeKey": o.modeKey
    };
  }

  function updatePendingCount() {
    var count = 0;
    for (var i = 0; i < draft.count; i++) {
      var item = draft.get(i);
      var live = DisplayService.outputByName(item.name);
      if (!live || DisplayService.signatureOf(item) !== DisplayService.signatureOf(live))
        count++;
    }
    pendingCount = count;
  }

  function commit() {
    publish();
    updatePendingCount();
    refreshSelected();
    draftRevision++;
  }

  function enabledCount() {
    var count = 0;
    for (var i = 0; i < draft.count; i++) {
      if (draft.get(i).enabled)
        count++;
    }
    return count;
  }

  function signatureOfOutputs(outputs) {
    var parts = [];
    for (var i = 0; i < outputs.length; i++)
      parts.push(DisplayService.signatureOf(outputs[i]));
    parts.sort();
    return parts.join(";");
  }

  function syncFromService(force) {
    if (!available)
      return;

    var liveSignature = signatureOfOutputs(DisplayService.outputs);

    if (dirty && !force) {
      if (liveSignature !== _liveSignature)
        externalChanged = true;
      return;
    }

    if (!force && liveSignature === _liveSignature && draft.count === DisplayService.outputs.length)
      return;

    _liveSignature = liveSignature;

    var outputs = DisplayService.outputs;
    draft.clear();

    for (var i = 0; i < outputs.length; i++) {
      var o = outputs[i];
      draft.append({
                     "name": o.name,
                     "description": o.description,
                     "make": o.make,
                     "modelName": o.model,
                     "enabled": o.enabled,
                     "focused": o.focused,
                     "width": o.width,
                     "height": o.height,
                     "refresh": o.refresh,
                     "scale": o.scale,
                     "transform": o.transform,
                     "vrr": o.vrr,
                     "x": o.x,
                     "y": o.y,
                     "mirror": o.mirror,
                     "bitdepth": o.bitdepth,
                     "cm": o.cm,
                     "sdrBrightness": o.sdrBrightness,
                     "sdrSaturation": o.sdrSaturation,
                     "modesJson": JSON.stringify(o.modes || []),
                     "modeKey": o.modeKey
                   });
    }

    externalChanged = false;

    if (indexOfOutput(selectedName) < 0)
      selectedName = outputs.length > 0 ? outputs[0].name : "";

    commit();
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------
  function setEnabled(name, value) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;

    if (!value && enabledCount() <= 1) {
      ToastService.showWarning(I18n.tr("panels.display.monitors-nav"), I18n.tr("panels.display.monitors-last-output"));
      return;
    }

    draft.setProperty(index, "enabled", value);

    // A display that was switched off before this page saw it can come back
    // with no mode selected; pick its first available one instead of leaving
    // an unresolvable rule behind.
    if (value && Number(draft.get(index).width) <= 0) {
      var modes = [];
      try {
        modes = JSON.parse(draft.get(index).modesJson || "[]");
      } catch (e) {
        modes = [];
      }
      if (modes.length > 0) {
        draft.setProperty(index, "width", modes[0].width);
        draft.setProperty(index, "height", modes[0].height);
        draft.setProperty(index, "refresh", modes[0].refresh);
        draft.setProperty(index, "modeKey", modes[0].key);
      }
    }

    commit();
  }

  function setMode(name, width, height, refresh) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;

    draft.setProperty(index, "width", width);
    draft.setProperty(index, "height", height);
    draft.setProperty(index, "refresh", refresh);
    draft.setProperty(index, "modeKey", DisplayService.modeKey(width, height, refresh));
    commit();
  }

  function setScale(name, value) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;
    draft.setProperty(index, "scale", Math.round(Number(value) * 100) / 100);
    commit();
  }

  function setTransform(name, value) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;
    draft.setProperty(index, "transform", value);
    commit();
  }

  function setPosition(name, x, y) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;
    draft.setProperty(index, "x", Math.round(Number(x) || 0));
    draft.setProperty(index, "y", Math.round(Number(y) || 0));
    commit();
  }

  function setVrr(name, value) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;
    draft.setProperty(index, "vrr", value);
    commit();
  }

  function setMirror(name, value) {
    var index = indexOfOutput(name);
    if (index < 0)
      return;
    draft.setProperty(index, "mirror", value || "");
    commit();
  }

  function autoPlace() {
    var arranged = DisplayService.autoArrange(layout);
    for (var i = 0; i < arranged.length; i++) {
      var index = indexOfOutput(arranged[i].name);
      if (index < 0)
        continue;
      draft.setProperty(index, "x", arranged[i].x);
      draft.setProperty(index, "y", arranged[i].y);
    }
    commit();
  }

  function discardChanges() {
    DisplayService.clearErrors();
    syncFromService(true);
  }

  function applyChanges() {
    if (!available || busy)
      return;
    DisplayService.applyLayout(layout, Settings.data.display.persistLayout);
  }

  function copySnippet() {
    Quickshell.execDetached(["wl-copy", persistSnippet]);
    ToastService.showNotice(I18n.tr("panels.display.monitors-nav"), I18n.tr("panels.display.monitors-copied"));
  }

  // ---------------------------------------------------------------------------
  // Lifecycle / service sync
  // ---------------------------------------------------------------------------
  Component.onCompleted: {
    _initialized = true;
    if (available) {
      DisplayService.refresh();
      syncFromService(true);
    }
    DisplayService.live = visible;
  }

  Component.onDestruction: {
    DisplayService.live = false;
  }

  onVisibleChanged: {
    if (!_initialized || !available)
      return;
    DisplayService.live = visible;
    if (visible) {
      DisplayService.refresh();
      if (!dirty)
        syncFromService(false);
    }
  }

  Connections {
    target: DisplayService
    enabled: root.available

    function onRevisionChanged() {
      if (DisplayService.applying)
        return;
      root.syncFromService(false);
    }

    function onApplyFinished(ok, message) {
      if (ok) {
        root.syncFromService(true);
        ToastService.showNotice(I18n.tr("panels.display.monitors-nav"), I18n.tr("panels.display.monitors-applied"));
      } else {
        // Rebase the live signature so the refresh that follows our own failed
        // apply does not look like somebody else changed the layout.
        root._liveSignature = root.signatureOfOutputs(DisplayService.outputs);
        root.updatePendingCount();
        ToastService.showError(I18n.tr("panels.display.monitors-nav"), I18n.tr("panels.display.monitors-apply-failed"));
        root.refreshSelected();
      }
    }

    function onPersisted(ok, path) {
      if (ok)
        ToastService.showNotice(I18n.tr("panels.display.monitors-nav"), I18n.tr("panels.display.monitors-saved", {
                                                                                       "path": path
                                                                                     }));
      else
        ToastService.showError(I18n.tr("panels.display.monitors-nav"), I18n.tr("panels.display.monitors-persist-failed"));
    }

    function onRefreshFailed(message) {
      if (root.visible)
        ToastService.showWarning(I18n.tr("panels.display.monitors-nav"), message);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  NText {
    Layout.fillWidth: true
    visible: !root.available
    text: I18n.tr("panels.display.monitors-unsupported", {
                    "compositor": DisplayService.compositorName
                  })
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
  }

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.marginL
    visible: root.available

    // Header
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.marginXXS

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.display.monitors-heading")
          pointSize: Style.fontSizeL
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
        }

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.display.monitors-heading-desc")
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
          wrapMode: Text.WordWrap
        }
      }

      NIconButton {
        icon: "refresh"
        tooltipText: I18n.tr("common.refresh")
        enabled: !root.busy
        baseSize: Style.baseWidgetSize * 0.8
        onClicked: DisplayService.refresh()
      }
    }

    // Errors from the last apply
    NBox {
      Layout.fillWidth: true
      implicitHeight: errorContent.implicitHeight + Style.margin2M
      color: Color.mError
      visible: DisplayService.applyErrors.length > 0

      NText {
        id: errorContent
        anchors.fill: parent
        anchors.margins: Style.marginM
        text: DisplayService.applyErrors.join("\n")
        pointSize: Style.fontSizeS
        color: Color.mOnError
        wrapMode: Text.WordWrap
        verticalAlignment: Text.AlignVCenter
      }
    }

    // External change (another tool, hotplug) while the draft is dirty
    NBox {
      Layout.fillWidth: true
      implicitHeight: externalContent.implicitHeight + Style.margin2M
      color: Color.mTertiary
      visible: root.externalChanged

      RowLayout {
        id: externalContent
        anchors.fill: parent
        anchors.margins: Style.marginM
        spacing: Style.marginM

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.display.monitors-external")
          pointSize: Style.fontSizeS
          color: Color.mOnTertiary
          wrapMode: Text.WordWrap
        }

        NButton {
          text: I18n.tr("panels.display.monitors-external-reload")
          outlined: true
          backgroundColor: Color.mOnTertiary
          textColor: Color.mOnTertiary
          textHoverColor: Color.mTertiary
          onClicked: root.syncFromService(true)
        }
      }
    }

    // Arrangement
    NBox {
      Layout.fillWidth: true
      implicitHeight: Math.round(300 * Style.uiScaleRatio) + Style.margin2M

      DisplayArrangementCanvas {
        id: canvasItem
        anchors.fill: parent
        anchors.margins: Style.marginM
        draftModel: root.draft
        selectedName: root.selectedName
        revision: root.draftRevision
        snapToEdges: Settings.data.display.snapToEdges
        onSelectRequested: function (name) {
          root.selectedName = name;
          root.refreshSelected();
        }
        onPositionRequested: function (name, x, y) {
          root.setPosition(name, x, y);
        }
      }
    }

    // Output chips
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      Repeater {
        model: root.draft

        delegate: Rectangle {
          required property var model

          readonly property bool selected: root.selectedName === model.name

          Layout.preferredWidth: chipLabel.implicitWidth + Style.margin2M
          Layout.preferredHeight: chipLabel.implicitHeight + Style.marginS
          radius: Style.radiusS
          color: selected ? Qt.alpha(Color.mPrimary, 0.18) : Color.smartAlpha(Color.mSurfaceVariant)
          border.width: selected ? Math.max(2, Style.borderM) : Style.borderS
          border.color: selected ? Color.mPrimary : Color.mOutline
          opacity: model.enabled ? 1.0 : 0.55

          NText {
            id: chipLabel
            anchors.centerIn: parent
            text: (model.enabled ? "" : "○ ") + (model.focused ? "● " : "") + model.name
            pointSize: Style.fontSizeS
            font.weight: selected ? Style.fontWeightBold : Style.fontWeightMedium
            color: Color.mOnSurface
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.selectedName = model.name;
              root.refreshSelected();
            }
          }
        }
      }

      Item {
        Layout.fillWidth: true
      }
    }

    // Inspector
    NBox {
      Layout.fillWidth: true
      implicitHeight: inspectorItem.implicitHeight + Style.margin2L

      DisplayOutputInspector {
        id: inspectorItem
        anchors.fill: parent
        anchors.margins: Style.marginL
        output: root.selectedOutput
        outputs: root.layout
        busy: root.busy
        onOutputEnabledChanged: function (value) {
          root.setEnabled(root.selectedName, value);
        }
        onModeSelected: function (width, height, refresh) {
          root.setMode(root.selectedName, width, height, refresh);
        }
        onOutputScaleChanged: function (value) {
          root.setScale(root.selectedName, value);
        }
        onTransformChanged: function (value) {
          root.setTransform(root.selectedName, value);
        }
        onPositionChanged: function (x, y) {
          root.setPosition(root.selectedName, x, y);
        }
        onVrrChanged: function (value) {
          root.setVrr(root.selectedName, value);
        }
        onMirrorChanged: function (value) {
          root.setMirror(root.selectedName, value);
        }
      }
    }

    // Persistence
    NBox {
      Layout.fillWidth: true
      implicitHeight: persistContent.implicitHeight + Style.margin2L

      ColumnLayout {
        id: persistContent
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginS

        NToggle {
          Layout.fillWidth: true
          label: I18n.tr("panels.display.monitors-persist-label")
          description: I18n.tr("panels.display.monitors-persist-desc", {
                                  "path": DisplayService.persistencePath
                                })
          checked: Settings.data.display.persistLayout
          onToggled: function (checked) {
            Settings.data.display.persistLayout = checked;
          }
        }

        NText {
          Layout.fillWidth: true
          visible: DisplayService.configChecked && !DisplayService.persistenceWired
          text: I18n.tr("panels.display.monitors-persist-unwired", {
                          "file": DisplayService.persistsLua ? DisplayService.luaPath : DisplayService.confPath,
                          "snippet": root.persistSnippet
                        })
          pointSize: Style.fontSizeS
          color: Color.mError
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          visible: DisplayService.configChecked && !DisplayService.persistenceWired
          spacing: Style.marginS

          NText {
            Layout.fillWidth: true
            text: root.persistSnippet
            pointSize: Style.fontSizeS
            family: Settings.data.ui.fontFixed
            color: Color.mOnSurfaceVariant
            elide: Text.ElideMiddle
          }

          NButton {
            text: I18n.tr("panels.display.monitors-copy")
            outlined: true
            onClicked: root.copySnippet()
          }
        }

        NText {
          Layout.fillWidth: true
          visible: DisplayService.lastSavedMs > 0
          text: I18n.tr("panels.display.monitors-last-saved", {
                          "time": Qt.formatDateTime(new Date(DisplayService.lastSavedMs), "HH:mm:ss"),
                          "path": DisplayService.lastSavedPath
                        })
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
          wrapMode: Text.WordWrap
        }
      }
    }

    // Warnings + actions
    NBox {
      Layout.fillWidth: true
      implicitHeight: actionContent.implicitHeight + Style.margin2L

      ColumnLayout {
        id: actionContent
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginM

        NText {
          Layout.fillWidth: true
          visible: root.overlapPairs.length > 0
          text: I18n.tr("panels.display.monitors-overlap", {
                          "outputs": root.overlapPairs.map(function (pair) {
                            return pair.join(" / ");
                          }).join(", ")
                        })
          pointSize: Style.fontSizeS
          color: Color.mError
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.marginM

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.marginXXS

            NText {
              Layout.fillWidth: true
              text: root.busy ? I18n.tr("panels.display.monitors-applying") : (root.dirty ? I18n.trp("panels.display.monitors-pending", root.pendingCount) : I18n.tr("panels.display.monitors-in-sync"))
              pointSize: Style.fontSizeS
              color: root.dirty ? Color.mPrimary : Color.mOnSurfaceVariant
              wrapMode: Text.WordWrap
            }

            NText {
              Layout.fillWidth: true
              visible: !Settings.data.display.persistLayout
              text: I18n.tr("panels.display.monitors-runtime-only")
              pointSize: Style.fontSizeXS
              color: Color.mOnSurfaceVariant
              wrapMode: Text.WordWrap
            }
          }

          NButton {
            text: I18n.tr("panels.display.monitors-auto-place")
            outlined: true
            enabled: !root.busy
            onClicked: root.autoPlace()
          }

          NButton {
            text: I18n.tr("common.reset")
            outlined: true
            enabled: root.dirty && !root.busy
            onClicked: root.discardChanges()
          }

          NButton {
            text: I18n.tr("common.apply")
            enabled: root.dirty && !root.busy
            onClicked: root.applyChanges()
          }
        }
      }
    }
  }
}
