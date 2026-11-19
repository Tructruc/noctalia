import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Modules.Panels.Settings // For SettingsPanel
import qs.Services.Networking
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property ShellScreen screen

  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  property var widgetMetadata: BarWidgetRegistry.widgetMetadata[widgetId] ?? {}
  // Explicit screenName property ensures reactive binding when screen changes
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

  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isBarVertical: barPosition === "left" || barPosition === "right"
  readonly property string displayMode: widgetSettings.displayMode !== undefined ? widgetSettings.displayMode : widgetMetadata.displayMode
  readonly property string iconColorKey: widgetSettings.iconColor !== undefined ? widgetSettings.iconColor : widgetMetadata.iconColor
  readonly property string textColorKey: widgetSettings.textColor !== undefined ? widgetSettings.textColor : widgetMetadata.textColor

  implicitWidth: pill.width
  implicitHeight: pill.height

  NPopupContextMenu {
    id: contextMenu

    model: {
      const items = [];

      // An activation in flight gets cancel at the top: it is the only way
      // out of a connection that is not going to complete.
      if (VPNService.connectingUuid) {
        const pending = VPNService.connections[VPNService.connectingUuid];
        items.push({
                     "label": I18n.tr("actions.cancel-vpn", {
                                        "name": pending ? pending.name : ""
                                      }),
                     "action": "cancel",
                     "icon": "x"
                   });
      }

      const active = VPNService.activeConnections;
      for (let i = 0; i < active.length; ++i) {
        const conn = active[i];
        items.push({
                     "label": I18n.tr("actions.disconnect-vpn", {
                                        "name": conn.name
                                      }),
                     "action": "disconnect:" + conn.uuid,
                     "icon": "shield-off"
                   });
      }
      const inactive = VPNService.inactiveConnections;
      for (let i = 0; i < inactive.length; ++i) {
        const conn = inactive[i];
        items.push({
                     "label": I18n.tr("actions.connect-vpn", {
                                        "name": conn.name
                                      }),
                     "action": "connect:" + conn.uuid,
                     "icon": "shield-lock"
                   });
      }
      items.push({
                   "label": I18n.tr("actions.manage-vpn"),
                   "action": "manage",
                   "icon": "adjustments"
                 });
      items.push({
                   "label": I18n.tr("actions.widget-settings"),
                   "action": "widget-settings",
                   "icon": "settings"
                 });
      return items;
    }

    onTriggered: action => {
                   contextMenu.close();
                   PanelService.closeContextMenu(screen);

                   if (!action) {
                     return;
                   }
                   if (action === "widget-settings") {
                     BarService.openWidgetSettings(screen, section, sectionWidgetIndex, widgetId, widgetSettings);
                     return;
                   }
                   if (action === "manage") {
                     SettingsPanelService.openToTab(SettingsPanel.Tab.Connections, 2, screen);
                     return;
                   }
                   if (action === "cancel") {
                     VPNService.cancel();
                     return;
                   }
                   if (action.startsWith("connect:")) {
                     const uuid = action.substring("connect:".length);
                     VPNService.connect(uuid);
                     return;
                   }
                   if (action.startsWith("disconnect:")) {
                     const uuid = action.substring("disconnect:".length);
                     VPNService.disconnect(uuid);
                   }
                 }
  }

  BarPill {
    id: pill

    screen: root.screen
    oppositeDirection: BarService.getPillDirection(root)
    customIconColor: Color.resolveColorKeyOptional(root.iconColorKey)
    customTextColor: Color.resolveColorKeyOptional(root.textColorKey)
    // One glyph per tunnel: the shield for a NetworkManager profile, the
    // network glyph for Tailscale. Both are drawn when both are up, so
    // connecting a profile does not hide the tailnet. The plain shield is the
    // idle state and keeps the widget from disappearing.
    icons: {
      const list = [];
      if (VPNService.hasActiveConnection)
        list.push("shield-lock");
      if (TailscaleService.running)
        list.push("network");
      if (list.length === 0)
        list.push("shield");
      return list;
    }
    text: {
      if (VPNService.activeConnections.length > 0) {
        return VPNService.activeConnections[0].name;
      }
      if (VPNService.connectingUuid) {
        const pending = VPNService.connections[VPNService.connectingUuid];
        if (pending) {
          return pending.name;
        }
      }
      if (TailscaleService.running)
        return I18n.tr("panels.vpn.tailscale");
      return "";
    }
    suffix: {
      if (VPNService.activeConnections.length > 1) {
        return ` + ${VPNService.activeConnections.length - 1}`;
      }
      return "";
    }
    autoHide: false
    forceOpen: !isBarVertical && root.displayMode === "alwaysShow"
    forceClose: isBarVertical || root.displayMode === "alwaysHide" || !pill.text
    // Left click opens the VPN panel, matching the network and bluetooth
    // widgets. Right click keeps the quick connect/disconnect menu.
    onClicked: {
      var p = PanelService.getPanel("vpnPanel", screen);
      if (p)
        p.toggle(pill);
    }
    onRightClicked: {
      PanelService.showContextMenu(contextMenu, pill, screen);
    }
    tooltipText: {
      // Same order as the glyphs: the profile first, then the tailnet.
      const parts = [];
      for (let i = 0; i < VPNService.activeConnections.length; ++i) {
        parts.push(VPNService.activeConnections[i].name);
      }
      if (TailscaleService.running) {
        parts.push(I18n.tr("panels.vpn.tailscale") + (TailscaleService.primaryIp !== "" ? " · " + TailscaleService.primaryIp : ""));
      }
      if (parts.length > 0) {
        return parts.join("  ·  ");
      }
      return I18n.tr("tooltips.manage-vpn");
    }
  }
}
