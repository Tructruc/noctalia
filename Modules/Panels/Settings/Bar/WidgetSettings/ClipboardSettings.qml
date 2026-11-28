import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginM

  // Properties to receive data from parent
  property var screen: null
  property var widgetData: null
  property var widgetMetadata: null

  signal settingsChanged(var settings)

  // Local state
  property bool valueShowBadge: widgetData.showBadge !== undefined ? widgetData.showBadge : widgetMetadata.showBadge
  property string valueIconColor: widgetData.iconColor !== undefined ? widgetData.iconColor : widgetMetadata.iconColor

  function saveSettings() {
    var settings = Object.assign({}, widgetData || {});
    settings.showBadge = valueShowBadge;
    settings.iconColor = valueIconColor;
    settingsChanged(settings);
  }

  NToggle {
    label: I18n.tr("bar.clipboard.show-badge-label")
    description: I18n.tr("bar.clipboard.show-badge-description")
    checked: valueShowBadge
    onToggled: checked => {
                 valueShowBadge = checked;
                 saveSettings();
               }
    defaultValue: widgetMetadata.showBadge
  }

  NColorChoice {
    label: I18n.tr("common.select-icon-color")
    currentKey: valueIconColor
    onSelected: key => {
                  valueIconColor = key;
                  saveSettings();
                }
    defaultValue: widgetMetadata.iconColor
  }
}
