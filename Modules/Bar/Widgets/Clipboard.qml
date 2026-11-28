import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Modules.Panels.Settings
import qs.Services.Keyboard
import qs.Services.UI
import qs.Widgets

NIconButton {
  id: root

  property ShellScreen screen

  // Widget properties passed from Bar.qml for per-instance settings
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  property var widgetMetadata: BarWidgetRegistry.widgetMetadata[widgetId] ?? {}
  // Explicit screenName ensures a reactive binding when the screen changes
  readonly property string screenName: screen ? screen.name : ""
  property var widgetSettings: {
    if (section && sectionWidgetIndex >= 0 && screenName) {
      var widgets = Settings.getBarWidgetsForScreen(screenName)[section];
      if (widgets && sectionWidgetIndex < widgets.length) {
        return widgets[sectionWidgetIndex];
      }
    }
    return {};
  }

  readonly property bool showBadge: widgetSettings.showBadge !== undefined ? widgetSettings.showBadge : widgetMetadata.showBadge
  readonly property string iconColorKey: widgetSettings.iconColor !== undefined ? widgetSettings.iconColor : widgetMetadata.iconColor

  readonly property int count: ClipboardService.items.length

  baseSize: Style.getCapsuleHeightForScreen(screen?.name)
  applyUiScale: false
  customRadius: Style.radiusL
  icon: "clipboard"
  tooltipText: PanelService.getPanel("clipboardPanel", screen)?.isPanelOpen ? "" : I18n.tr("tooltips.open-clipboard")
  tooltipDirection: BarService.getTooltipDirection(screen?.name)
  colorBg: Style.capsuleColor
  colorFg: Color.resolveColorKey(iconColorKey)
  border.color: Style.capsuleBorderColor
  border.width: Style.capsuleBorderWidth

  Loader {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    anchors.horizontalCenterOffset: parent.baseSize / 4
    anchors.verticalCenterOffset: -parent.baseSize / 4
    z: 2
    active: root.showBadge && root.count > 0
    sourceComponent: Rectangle {
      id: badge
      height: 7
      width: height
      radius: Style.radiusXS
      color: root.hovering ? Color.mOnHover : Color.mPrimary
      border.color: Color.mSurface
      border.width: Style.borderS
      visible: root.count > 0
    }
  }

  NPopupContextMenu {
    id: contextMenu

    model: [
      {
        "label": I18n.tr("clipboard.clear-history"),
        "action": "clear-history",
        "icon": "trash"
      },
      {
        "label": I18n.tr("clipboard.settings"),
        "action": "clipboard-settings",
        "icon": "clipboard"
      },
      {
        "label": I18n.tr("actions.widget-settings"),
        "action": "widget-settings",
        "icon": "settings"
      }
    ]

    onTriggered: action => {
                   contextMenu.close();
                   PanelService.closeContextMenu(screen);

                   if (action === "clear-history") {
                     ClipboardService.wipeAll();
                   } else if (action === "clipboard-settings") {
                     SettingsPanelService.openToTab(SettingsPanel.Tab.Launcher, 1, screen);
                   } else if (action === "widget-settings") {
                     BarService.openWidgetSettings(screen, section, sectionWidgetIndex, widgetId, widgetSettings);
                   }
                 }
  }

  onClicked: {
    var panel = PanelService.getPanel("clipboardPanel", screen);
    panel?.toggle(root);
  }

  onRightClicked: {
    PanelService.showContextMenu(contextMenu, root, screen);
  }
}
