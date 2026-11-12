import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../Settings/Tabs/Connections" as VpnPrefs
import qs.Commons
import qs.Modules.MainScreen
import qs.Modules.Panels.Settings
import qs.Services.Networking
import qs.Services.UI
import qs.Widgets

// VPN panel for the bar widget. Same shape as the Bluetooth and network
// panels: a header with the service state, then the list. The list itself is
// VpnSubTab with showOnlyLists, so the panel and Settings > Connections > VPN
// share one implementation instead of drifting apart.
SmartPanel {
  id: root

  preferredWidth: Math.round(460 * Style.uiScaleRatio)
  preferredHeight: Math.round(520 * Style.uiScaleRatio)

  panelContent: Rectangle {
    id: panelContent
    color: "transparent"

    ColumnLayout {
      id: mainColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginM

      // ---------------------------------------------------------------- header
      NBox {
        Layout.fillWidth: true
        Layout.preferredHeight: headerRow.implicitHeight + Style.margin2M

        RowLayout {
          id: headerRow
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginM

          NIcon {
            icon: VPNService.hasActiveConnection ? "shield-lock" : "shield"
            pointSize: Style.fontSizeXXL
            color: VPNService.hasActiveConnection ? Color.mPrimary : Color.mOnSurfaceVariant
          }

          NLabel {
            Layout.fillWidth: true
            label: I18n.tr("common.vpn")
          }

          // Cancel sits in the header while an activation is in flight, so the
          // escape hatch is reachable without scrolling to the profile.
          NIconButton {
            visible: VPNService.connecting
            icon: "x"
            tooltipText: I18n.tr("panels.vpn.cancel-tooltip")
            baseSize: Style.baseWidgetSize * 0.8
            onClicked: VPNService.cancel()
          }

          NIconButton {
            icon: "refresh"
            tooltipText: I18n.tr("panels.vpn.refresh-tooltip")
            baseSize: Style.baseWidgetSize * 0.8
            enabled: !VPNService.refreshing
            onClicked: VPNService.refresh()
          }

          NIconButton {
            icon: "settings"
            tooltipText: I18n.tr("tooltips.open-settings")
            baseSize: Style.baseWidgetSize * 0.8
            onClicked: SettingsPanelService.openToTab(SettingsPanel.Tab.Connections, 2, screen)
          }

          NIconButton {
            icon: "close"
            tooltipText: I18n.tr("common.close")
            baseSize: Style.baseWidgetSize * 0.8
            onClicked: root.close()
          }
        }
      }

      // ---------------------------------------------------------------- list
      NScrollView {
        id: vpnScrollView
        Layout.fillWidth: true
        Layout.fillHeight: true
        horizontalPolicy: ScrollBar.AlwaysOff
        verticalPolicy: ScrollBar.AsNeeded
        reserveScrollbarSpace: false
        gradientColor: Color.mSurface

        VpnPrefs.VpnSubTab {
          id: vpnList
          width: vpnScrollView.availableWidth
          showOnlyLists: true
        }
      }
    }
  }
}
