import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.Display
import qs.Widgets

// Per-output controls for the draft layout. Values are emitted upwards; the
// page owns the draft and applies nothing until Apply is pressed.
ColumnLayout {
  id: root

  property var output: ({})
  property var outputs: []
  property bool busy: false

  property real localScale: 1.0
  property string xText: ""
  property string yText: ""

  signal outputEnabledChanged(bool value)
  signal modeSelected(int width, int height, real refresh)
  signal outputScaleChanged(real value)
  signal transformChanged(int value)
  signal positionChanged(int x, int y)
  signal vrrChanged(bool value)
  signal mirrorChanged(string value)

  spacing: Style.marginL
  Layout.fillWidth: true

  readonly property bool hasOutput: !!(output && output.name)
  readonly property bool mirrored: hasOutput && (output.mirror || "") !== ""
  readonly property bool configurable: hasOutput && output.enabled === true && !mirrored
  readonly property string scaleText: {
    var scale = Number(localScale || 1.0);
    return scale.toFixed(2).replace(/0+$/, "").replace(/\.$/, "") + "×";
  }

  function modeModel() {
    var model = [];
    var modes = (output && output.modes) ? output.modes : [];
    for (var i = 0; i < modes.length; i++) {
      model.push({
                   "key": modes[i].key,
                   "name": modes[i].label
                 });
    }
    return model;
  }

  function selectMode(key) {
    var modes = (output && output.modes) ? output.modes : [];
    for (var i = 0; i < modes.length; i++) {
      if (modes[i].key === key) {
        root.modeSelected(modes[i].width, modes[i].height, modes[i].refresh);
        return;
      }
    }
  }

  Timer {
    id: positionDebounce
    interval: 450
    repeat: false
    onTriggered: root.commitPosition()
  }

  function commitPosition() {
    if (!output || !output.name)
      return;
    var x = parseInt(xText.trim());
    var y = parseInt(yText.trim());
    if (isNaN(x))
      x = output.x;
    if (isNaN(y))
      y = output.y;
    root.positionChanged(Math.round(x), Math.round(y));
  }

  function syncLocalValues() {
    if (!output || !output.name) {
      localScale = 1.0;
      xText = "";
      yText = "";
      return;
    }
    localScale = Number(output.scale) || 1.0;
    // Do not rewrite a coordinate while it is being typed: a negative sign or
    // a partially typed number would be replaced mid-edit.
    if (!xField.inputItem.activeFocus)
      xText = String(Math.round(output.x || 0));
    if (!yField.inputItem.activeFocus)
      yText = String(Math.round(output.y || 0));
  }

  onOutputChanged: syncLocalValues()
  Component.onCompleted: syncLocalValues()

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginM

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.marginXXS

      NText {
        Layout.fillWidth: true
        text: root.hasOutput ? root.output.name : I18n.tr("panels.display.monitors-select-output")
        pointSize: Style.fontSizeL
        font.weight: Style.fontWeightBold
        color: Color.mOnSurface
      }

      NText {
        Layout.fillWidth: true
        visible: root.hasOutput
        text: {
          if (!root.hasOutput)
            return "";
          var parts = [];
          if (root.output.make)
            parts.push(root.output.make);
          if (root.output.modelName && root.output.modelName !== root.output.make)
            parts.push(root.output.modelName);
          if (root.output.description && root.output.description !== parts.join(" "))
            parts.push(root.output.description);
          return parts.join(" · ");
        }
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        elide: Text.ElideRight
      }
    }
  }

  NToggle {
    Layout.fillWidth: true
    visible: root.hasOutput
    label: I18n.tr("panels.display.monitors-enabled-label")
    description: I18n.tr("panels.display.monitors-enabled-desc")
    checked: root.hasOutput ? root.output.enabled === true : false
    onToggled: function (checked) {
      root.outputEnabledChanged(checked);
    }
  }

  NText {
    Layout.fillWidth: true
    visible: root.hasOutput && !root.output.enabled
    text: I18n.tr("panels.display.monitors-disabled-desc")
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
  }

  NComboBox {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    enabled: root.configurable && !root.busy
    label: I18n.tr("panels.display.monitors-mode-label")
    description: root.mirrored ? I18n.tr("panels.display.monitors-mirror-fixed-desc") : I18n.tr("panels.display.monitors-mode-desc")
    model: root.modeModel()
    currentKey: root.hasOutput ? (root.output.modeKey || "") : ""
    popupHeight: 260
    onSelected: function (key) {
      root.selectMode(key);
    }
  }

  NValueSlider {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    enabled: root.configurable && !root.busy
    label: I18n.tr("panels.display.monitors-scale-label")
    description: root.mirrored ? I18n.tr("panels.display.monitors-mirror-fixed-desc") : I18n.tr("panels.display.monitors-scale-desc")
    from: 0.5
    to: 3.0
    stepSize: 0.05
    value: root.localScale
    text: root.scaleText
    onMoved: function (value) {
      root.localScale = value;
      root.outputScaleChanged(value);
    }
  }

  NComboBox {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    enabled: root.configurable && !root.busy
    label: I18n.tr("panels.display.monitors-rotation-label")
    description: root.mirrored ? I18n.tr("panels.display.monitors-mirror-fixed-desc") : I18n.tr("panels.display.monitors-rotation-desc")
    model: [
      {
        "key": "0",
        "name": I18n.tr("panels.display.monitors-rotation-normal")
      },
      {
        "key": "1",
        "name": I18n.tr("panels.display.monitors-rotation-90")
      },
      {
        "key": "2",
        "name": I18n.tr("panels.display.monitors-rotation-180")
      },
      {
        "key": "3",
        "name": I18n.tr("panels.display.monitors-rotation-270")
      },
      {
        "key": "4",
        "name": I18n.tr("panels.display.monitors-rotation-flipped")
      },
      {
        "key": "5",
        "name": I18n.tr("panels.display.monitors-rotation-flipped-90")
      },
      {
        "key": "6",
        "name": I18n.tr("panels.display.monitors-rotation-flipped-180")
      },
      {
        "key": "7",
        "name": I18n.tr("panels.display.monitors-rotation-flipped-270")
      }
    ]
    currentKey: root.hasOutput ? String(root.output.transform || 0) : "0"
    onSelected: function (key) {
      root.transformChanged(parseInt(key) || 0);
    }
  }

  RowLayout {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    spacing: Style.marginL

    NTextInput {
      id: xField
      Layout.fillWidth: true
      enabled: root.configurable && !root.busy
      label: I18n.tr("panels.display.monitors-position-x-label")
      text: root.xText
      onTextChanged: positionDebounce.restart()
      onEditingFinished: root.commitPosition()
    }

    NTextInput {
      id: yField
      Layout.fillWidth: true
      enabled: root.configurable && !root.busy
      label: I18n.tr("panels.display.monitors-position-y-label")
      text: root.yText
      onTextChanged: positionDebounce.restart()
      onEditingFinished: root.commitPosition()
    }
  }

  NText {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    text: I18n.tr("panels.display.monitors-position-hint")
    pointSize: Style.fontSizeXS
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
  }

  NToggle {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    enabled: !root.busy
    label: I18n.tr("panels.display.monitors-vrr-label")
    description: root.mirrored ? I18n.tr("panels.display.monitors-mirror-fixed-desc") : I18n.tr("panels.display.monitors-vrr-desc")
    checked: root.hasOutput ? root.output.vrr === true : false
    onToggled: function (checked) {
      root.vrrChanged(checked);
    }
  }

  NComboBox {
    Layout.fillWidth: true
    visible: root.hasOutput && root.output.enabled === true
    enabled: !root.busy
    label: I18n.tr("panels.display.monitors-mirror-label")
    description: I18n.tr("panels.display.monitors-mirror-desc")
    model: {
      var model = [
            {
              "key": "",
              "name": I18n.tr("common.none")
            }
          ];
      for (var i = 0; i < root.outputs.length; i++) {
        var other = root.outputs[i];
        if (!other || other.name === root.output.name)
          continue;
        model.push({
                     "key": other.name,
                     "name": other.name + (other.modelName ? " · " + other.modelName : "")
                   });
      }
      return model;
    }
    currentKey: root.hasOutput ? (root.output.mirror || "") : ""
    onSelected: function (key) {
      root.mirrorChanged(key);
    }
  }

  NText {
    Layout.fillWidth: true
    visible: root.mirrored
    text: I18n.tr("panels.display.monitors-mirror-active", {
                    "output": root.output.mirror || ""
                  })
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
  }
}
