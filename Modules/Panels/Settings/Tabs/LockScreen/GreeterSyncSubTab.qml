import QtQuick
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

  readonly property var service: GreeterSyncService
  readonly property bool busy: service.syncing
  readonly property bool ready: service.helperInstalled && service.secureSync
  readonly property bool loginReady: root.ready && service.greetdActive
  readonly property string stateColor: root.loginReady ? Color.mPrimary : (root.ready ? Color.mTertiary : Color.mError)

  function copySwitchCommands() {
    var text = "# In /etc/greetd/config.toml set:\n"
      + "# command = \"/usr/bin/noctalia-greeter-session\"\n"
      + "sudo systemctl disable --now gdm\n"
      + "sudo systemctl enable --now greetd";
    Quickshell.execDetached(["wl-copy", text]);
    ToastService.showNotice(I18n.tr("panels.lock-screen.greeter-heading"), I18n.tr("panels.lock-screen.greeter-copied"));
  }

  Component.onCompleted: service.refreshStatus()

  onVisibleChanged: {
    if (visible)
      service.refreshStatus();
  }

  // Header -------------------------------------------------------------------
  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.marginXXS

    NText {
      Layout.fillWidth: true
      text: I18n.tr("panels.lock-screen.greeter-heading")
      pointSize: Style.fontSizeXL
      font.weight: Style.fontWeightBold
      color: Color.mOnSurface
    }

    NText {
      Layout.fillWidth: true
      text: I18n.tr("panels.lock-screen.greeter-desc")
      pointSize: Style.fontSizeS
      color: Color.mOnSurfaceVariant
      wrapMode: Text.WordWrap
    }
  }

  // Status -------------------------------------------------------------------
  NBox {
    Layout.fillWidth: true
    implicitHeight: statusColumn.implicitHeight + Style.margin2L
    color: Color.mSurface
    forceOpaque: true

    ColumnLayout {
      id: statusColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginS

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NIcon {
          icon: root.loginReady ? "check" : "alert-triangle"
          pointSize: Style.fontSizeM
          color: root.stateColor
        }

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.lock-screen.greeter-status")
          pointSize: Style.fontSizeL
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
        }

        NIconButton {
          icon: "refresh"
          tooltipText: I18n.tr("panels.lock-screen.greeter-refresh")
          baseSize: Style.baseWidgetSize * 0.65
          onClicked: root.service.refreshStatus()
        }
      }

      NDivider {
        Layout.fillWidth: true
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.lock-screen.greeter-helper")
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }

        NText {
          text: root.service.helperInstalled ? I18n.tr("panels.lock-screen.greeter-installed") : I18n.tr("panels.lock-screen.greeter-missing")
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightBold
          color: root.service.helperInstalled ? Color.mPrimary : Color.mError
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.lock-screen.greeter-secure")
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }

        NText {
          text: root.service.secureSync ? I18n.tr("panels.lock-screen.greeter-supported") : I18n.tr("panels.lock-screen.greeter-unsupported")
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightBold
          color: root.service.secureSync ? Color.mPrimary : Color.mError
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.lock-screen.greeter-greetd")
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }

        NText {
          text: root.service.greetdActive ? I18n.tr("panels.lock-screen.greeter-active") : I18n.tr("panels.lock-screen.greeter-inactive")
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightBold
          color: root.service.greetdActive ? Color.mPrimary : Color.mOnSurface
        }
      }

      NText {
        Layout.fillWidth: true
        visible: root.service.greetdActive === false
        text: I18n.tr("panels.lock-screen.greeter-switch-desc")
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
        wrapMode: Text.WordWrap
      }

      NButton {
        Layout.topMargin: Style.marginXXS
        visible: root.service.greetdActive === false
        text: I18n.tr("panels.lock-screen.greeter-copy-commands")
        outlined: true
        onClicked: root.copySwitchCommands()
      }

      NText {
        Layout.fillWidth: true
        visible: root.service.helperInstalled && !root.service.secureSync
        text: I18n.tr("panels.lock-screen.greeter-helper-old")
        pointSize: Style.fontSizeXS
        color: Color.mError
        wrapMode: Text.WordWrap
      }

      NText {
        Layout.fillWidth: true
        visible: !root.service.helperInstalled
        text: I18n.tr("panels.lock-screen.greeter-not-installed-desc")
        pointSize: Style.fontSizeXS
        color: Color.mError
        wrapMode: Text.WordWrap
      }
    }
  }

  // Sync ---------------------------------------------------------------------
  NBox {
    Layout.fillWidth: true
    implicitHeight: syncColumn.implicitHeight + Style.margin2L
    color: Color.mSurface
    forceOpaque: true

    ColumnLayout {
      id: syncColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginM

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NText {
          Layout.fillWidth: true
          text: I18n.tr("panels.lock-screen.greeter-sync")
          pointSize: Style.fontSizeL
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
        }

        NText {
          visible: root.service.lastSyncMs > 0
          text: root.service.lastSyncOk ? I18n.tr("panels.lock-screen.greeter-last-ok", {
                                                    "time": Qt.formatDateTime(new Date(root.service.lastSyncMs), "HH:mm:ss")
                                                  }) : I18n.tr("panels.lock-screen.greeter-last-failed")
          pointSize: Style.fontSizeXS
          color: root.service.lastSyncOk ? Color.mOnSurfaceVariant : Color.mError
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM

        NButton {
          text: root.busy ? I18n.tr("panels.lock-screen.greeter-syncing") : I18n.tr("panels.lock-screen.greeter-sync-now")
          enabled: root.service.available && !root.busy
          onClicked: root.service.syncNow()
        }

        NText {
          Layout.fillWidth: true
          visible: root.service.lastError !== ""
          text: root.service.lastError
          pointSize: Style.fontSizeXS
          color: Color.mError
          wrapMode: Text.WordWrap
        }
      }

      NDivider {
        Layout.fillWidth: true
      }

      NToggle {
        Layout.fillWidth: true
        labelSize: Style.fontSizeM
        label: I18n.tr("panels.lock-screen.greeter-auto")
        description: I18n.tr("panels.lock-screen.greeter-auto-desc")
        checked: Settings.data.general.greeterSync.autoSync
        enabled: root.service.available
        onToggled: function (checked) {
          Settings.data.general.greeterSync.autoSync = checked;
        }
      }

      NText {
        Layout.fillWidth: true
        text: I18n.tr("panels.lock-screen.greeter-polkit")
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
        wrapMode: Text.WordWrap
      }
    }
  }
}
