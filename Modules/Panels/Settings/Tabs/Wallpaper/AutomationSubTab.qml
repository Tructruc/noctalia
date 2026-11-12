import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginL
  Layout.fillWidth: true
  enabled: Settings.data.wallpaper.enabled

  NToggle {
    label: I18n.tr("panels.wallpaper.automation-scheduled-change-label")
    description: I18n.tr("panels.wallpaper.automation-scheduled-change-description")
    checked: Settings.data.wallpaper.automationEnabled
    onToggled: checked => Settings.data.wallpaper.automationEnabled = checked
  }

  ColumnLayout {
    enabled: Settings.data.wallpaper.automationEnabled
    spacing: Style.marginL
    Layout.fillWidth: true

    NComboBox {

      label: I18n.tr("panels.wallpaper.automation-change-mode-label")
      description: I18n.tr("panels.wallpaper.automation-change-mode-description")
      Layout.fillWidth: true
      model: [
        {
          "key": "random",
          "name": I18n.tr("common.random")
        },
        {
          "key": "alphabetical",
          "name": I18n.tr("panels.wallpaper.automation-change-mode-alphabetical")
        }
      ]
      currentKey: Settings.data.wallpaper.wallpaperChangeMode || "random"
      onSelected: key => Settings.data.wallpaper.wallpaperChangeMode = key
      defaultValue: Settings.getDefaultValue("wallpaper.wallpaperChangeMode")
    }

    NSpinBox {
      label: I18n.tr("panels.wallpaper.automation-interval-label")
      description: I18n.tr("panels.wallpaper.automation-interval-description")
      Layout.fillWidth: true
      from: 1
      to: 1440
      stepSize: 1
      suffix: "m"
      value: Math.round(Settings.data.wallpaper.randomIntervalSec / 60)
      defaultValue: Settings.getDefaultValue("wallpaper.randomIntervalSec") !== undefined ? Math.round(Settings.getDefaultValue("wallpaper.randomIntervalSec") / 60) : undefined
      onValueChanged: {
        let newSec = value * 60;
        if (newSec !== Settings.data.wallpaper.randomIntervalSec) {
          Settings.data.wallpaper.randomIntervalSec = newSec;
          WallpaperService.restartRandomWallpaperTimer();
        }
      }
    }
  }

  NDivider {
    Layout.fillWidth: true
  }

  NLabel {
    label: I18n.tr("panels.wallpaper.daily-label")
    description: I18n.tr("panels.wallpaper.daily-description")
  }

  NToggle {
    label: I18n.tr("panels.wallpaper.daily-enable-label")
    description: I18n.tr("panels.wallpaper.daily-enable-description")
    checked: Settings.data.wallpaper.dailyWallpaperEnabled
    onToggled: checked => Settings.data.wallpaper.dailyWallpaperEnabled = checked
  }

  ColumnLayout {
    enabled: Settings.data.wallpaper.dailyWallpaperEnabled
    spacing: Style.marginL
    Layout.fillWidth: true

    NComboBox {
      label: I18n.tr("panels.wallpaper.daily-source-label")
      description: I18n.tr("panels.wallpaper.daily-source-description")
      Layout.fillWidth: true
      model: DailyWallpaperService.sources
      currentKey: Settings.data.wallpaper.dailyWallpaperSource || "nasa-apod"
      onSelected: key => Settings.data.wallpaper.dailyWallpaperSource = key
      defaultValue: Settings.getDefaultValue("wallpaper.dailyWallpaperSource")
    }

    NSpinBox {
      label: I18n.tr("panels.wallpaper.daily-keepdays-label")
      description: I18n.tr("panels.wallpaper.daily-keepdays-description")
      Layout.fillWidth: true
      from: 1
      to: 60
      stepSize: 1
      suffix: "d"
      value: Settings.data.wallpaper.dailyWallpaperKeepDays
      defaultValue: Settings.getDefaultValue("wallpaper.dailyWallpaperKeepDays")
      onValueChanged: {
        if (value !== Settings.data.wallpaper.dailyWallpaperKeepDays) {
          Settings.data.wallpaper.dailyWallpaperKeepDays = value;
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginM

      NButton {
        text: I18n.tr("panels.wallpaper.daily-fetch-now")
        icon: "refresh"
        enabled: !DailyWallpaperService.fetching
        onClicked: DailyWallpaperService.check()
      }

      NLabel {
        Layout.fillWidth: true
        label: DailyWallpaperService.fetching ? I18n.tr("panels.wallpaper.daily-status-fetching") : (DailyWallpaperService.lastError !== "" ? DailyWallpaperService.lastError : (DailyWallpaperService.lastAppliedPath !== "" ? DailyWallpaperService.lastAppliedPath : I18n.tr("panels.wallpaper.daily-status-idle")))
        labelSize: Style.fontSizeS
      }
    }
  }
}
