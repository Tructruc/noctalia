import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Modules.MainScreen
import qs.Modules.Panels.Launcher
import qs.Modules.Panels.Settings
import qs.Services.Keyboard
import qs.Services.System
import qs.Services.UI
import qs.Widgets

// Dedicated clipboard history browser for the bar. The launcher's >clip mode stays as a
// quick picker; this panel is the full manager (preview, filters, keyboard).
SmartPanel {
  id: root

  preferredWidth: Math.round(820 * Style.uiScaleRatio)
  preferredHeight: Math.round(580 * Style.uiScaleRatio)

  panelContent: Rectangle {
    id: panelContent
    color: "transparent"
    focus: true

    property string filterText: ""
    property string category: "all"
    property int selectedIndex: -1
    property string selectedId: ""
    property var previewItem: null
    property bool clearArmed: false

    readonly property int revision: ClipboardService.revision
    readonly property var categories: [
      {
        "key": "all",
        "label": I18n.tr("clipboard.categories.all")
      },
      {
        "key": "text",
        "label": I18n.tr("clipboard.categories.text")
      },
      {
        "key": "image",
        "label": I18n.tr("clipboard.categories.image")
      },
      {
        "key": "link",
        "label": I18n.tr("clipboard.categories.link")
      },
      {
        "key": "file",
        "label": I18n.tr("clipboard.categories.file")
      },
      {
        "key": "code",
        "label": I18n.tr("clipboard.categories.code")
      },
      {
        "key": "color",
        "label": I18n.tr("clipboard.categories.color")
      }
    ]

    readonly property var filteredItems: {
      var _rev = revision;
      var source = ClipboardService.items || [];
      var query = filterText.trim().toLowerCase();
      var wanted = category;
      var out = [];
      var seen = {};
      for (var i = 0; i < source.length; ++i) {
        var item = source[i];
        if (!item || item.id === undefined)
          continue;
        var dedupeKey = item.isImage ? ("image:" + item.id) : (String(item.contentType) + ":" + String(item.preview || "").slice(0, 500));
        if (seen[dedupeKey])
          continue;
        seen[dedupeKey] = true;
        if (wanted !== "all" && item.contentType !== wanted)
          continue;
        if (query !== "") {
          var preview = String(item.preview || "").toLowerCase();
          if (preview.indexOf(query) === -1) {
            var cached = ClipboardService.getContent(item.id);
            if (!cached || cached.toLowerCase().indexOf(query) === -1)
              continue;
          }
        }
        out.push(item);
      }
      return out;
    }

    readonly property var categoryCounts: {
      var _rev = revision;
      var source = ClipboardService.items || [];
      var counts = {
        "all": 0,
        "text": 0,
        "image": 0,
        "link": 0,
        "file": 0,
        "code": 0,
        "color": 0
      };
      var seen = {};
      for (var i = 0; i < source.length; ++i) {
        var item = source[i];
        if (!item || item.id === undefined)
          continue;
        var dedupeKey = item.isImage ? ("image:" + item.id) : (String(item.contentType) + ":" + String(item.preview || "").slice(0, 500));
        if (seen[dedupeKey])
          continue;
        seen[dedupeKey] = true;
        counts.all++;
        if (counts[item.contentType] !== undefined)
          counts[item.contentType]++;
      }
      return counts;
    }

    readonly property int totalCount: categoryCounts.all
    readonly property bool hasContent: ClipboardService.active && filteredItems.length > 0
    readonly property bool showChips: ClipboardService.active && Settings.data.appLauncher.enableClipboardChips && totalCount > 0
    readonly property string countText: ClipboardService.active && totalCount > 0 ? I18n.tr("clipboard.item-count", {
                                                                                          "count": filteredItems.length
                                                                                        }) : ""
    readonly property bool showEnable: !Settings.data.appLauncher.enableClipboardHistory && ClipboardService.cliphistAvailable

    readonly property string stateTitle: {
      if (!ClipboardService.dependencyChecked)
        return I18n.tr("clipboard.loading-title");
      if (!ClipboardService.cliphistAvailable)
        return I18n.tr("clipboard.missing-title");
      if (!Settings.data.appLauncher.enableClipboardHistory)
        return I18n.tr("clipboard.disabled-title");
      if (ClipboardService.loading && totalCount === 0)
        return I18n.tr("clipboard.loading-title");
      if (totalCount === 0)
        return I18n.tr("clipboard.empty-title");
      return I18n.tr("clipboard.no-match-title");
    }

    readonly property string stateDescription: {
      if (!ClipboardService.dependencyChecked)
        return I18n.tr("clipboard.loading-description");
      if (!ClipboardService.cliphistAvailable)
        return I18n.tr("clipboard.missing-description");
      if (!Settings.data.appLauncher.enableClipboardHistory)
        return I18n.tr("clipboard.disabled-description");
      if (ClipboardService.loading && totalCount === 0)
        return I18n.tr("clipboard.loading-description");
      if (totalCount === 0)
        return I18n.tr("clipboard.empty-description");
      return I18n.tr("clipboard.no-match-description");
    }

    readonly property string stateIcon: totalCount > 0 ? "search" : "clipboard"

    function currentItem() {
      if (selectedIndex < 0 || selectedIndex >= filteredItems.length)
        return null;
      return filteredItems[selectedIndex];
    }

    function setSelection(index, scroll) {
      var items = filteredItems;
      if (!items || items.length === 0 || index < 0 || index >= items.length) {
        selectedIndex = -1;
        selectedId = "";
        previewItem = null;
        return;
      }

      var item = items[index];
      var itemId = String(item.id);
      selectedIndex = index;
      if (selectedId !== itemId || previewItem === null) {
        selectedId = itemId;
        previewItem = {
          "clipboardId": itemId,
          "preview": item.preview,
          "mime": item.mime,
          "isImage": item.isImage,
          "contentType": item.contentType
        };
      }
      if (scroll && listView)
        listView.positionViewAtIndex(index, ListView.Contain);
    }

    function ensureSelection() {
      var items = filteredItems;
      if (!items || items.length === 0) {
        selectedIndex = -1;
        selectedId = "";
        previewItem = null;
        return;
      }

      var next = -1;
      if (selectedId !== "") {
        for (var i = 0; i < items.length; ++i) {
          if (String(items[i].id) === selectedId) {
            next = i;
            break;
          }
        }
      }
      if (next < 0)
        next = Math.max(0, Math.min(selectedIndex < 0 ? 0 : selectedIndex, items.length - 1));
      setSelection(next, false);
    }

    function moveSelection(delta) {
      if (filteredItems.length === 0)
        return;
      var next = selectedIndex < 0 ? 0 : selectedIndex + delta;
      next = Math.max(0, Math.min(filteredItems.length - 1, next));
      setSelection(next, true);
    }

    function copyItem(item, paste) {
      if (!item)
        return;
      if (paste && ProgramCheckerService.wtypeAvailable) {
        ClipboardService.pasteFromClipboard(item.id, item.mime);
      } else {
        ClipboardService.copyToClipboard(item.id);
        ToastService.showNotice(I18n.tr("common.clipboard"), I18n.tr("common.copied-to-clipboard"), "clipboard");
      }
      root.close();
    }

    function activateSelection(paste) {
      copyItem(currentItem(), paste);
    }

    function deleteItem(item) {
      if (!item)
        return;
      ClipboardService.deleteById(item.id);
    }

    function deleteSelection() {
      deleteItem(currentItem());
    }

    function resetView() {
      filterText = "";
      category = "all";
      selectedIndex = -1;
      selectedId = "";
      previewItem = null;
      clearArmed = false;
      if (searchInput)
        searchInput.text = "";
      if (ClipboardService.active)
        ClipboardService.list(160);
      ensureSelection();
      Qt.callLater(function () {
        if (searchInput && searchInput.inputItem)
          searchInput.inputItem.forceActiveFocus();
      });
    }

    onFilteredItemsChanged: ensureSelection()

    Connections {
      target: ClipboardService
      function onListCompleted() {
        panelContent.ensureSelection();
      }
    }

    Connections {
      target: root
      function onOpened() {
        panelContent.resetView();
      }
    }

    Timer {
      id: clearTimer
      interval: 3000
      repeat: false
      onTriggered: panelContent.clearArmed = false
    }

    // Plain arrow/Return shortcuts are intentional: the search field keeps
    // focus for typing, so the list cannot get focus from the keyboard.
    Shortcut {
      sequence: "Up"
      enabled: root.isPanelOpen && panelContent.hasContent
      onActivated: panelContent.moveSelection(-1)
    }
    Shortcut {
      sequence: "Down"
      enabled: root.isPanelOpen && panelContent.hasContent
      onActivated: panelContent.moveSelection(1)
    }
    Shortcut {
      sequence: "Return"
      enabled: root.isPanelOpen && panelContent.hasContent
      onActivated: panelContent.activateSelection(false)
    }
    Shortcut {
      sequence: "Ctrl+Return"
      enabled: root.isPanelOpen && panelContent.hasContent
      onActivated: panelContent.activateSelection(true)
    }
    Shortcut {
      sequence: "Delete"
      enabled: root.isPanelOpen && panelContent.hasContent && searchInput.text === ""
      onActivated: panelContent.deleteSelection()
    }
    Shortcut {
      sequence: "Ctrl+F"
      enabled: root.isPanelOpen
      onActivated: {
        if (searchInput.inputItem)
          searchInput.inputItem.forceActiveFocus();
      }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginM

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NIcon {
          icon: "clipboard"
          pointSize: Style.fontSizeXL
          color: Color.mPrimary
        }

        NText {
          Layout.fillWidth: true
          text: I18n.tr("common.clipboard")
          pointSize: Style.fontSizeL
          font.weight: Style.fontWeightBold
          color: Color.mOnSurface
        }

        NText {
          text: panelContent.countText
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
          visible: text !== ""
        }

        NIconButton {
          icon: panelContent.clearArmed ? "check" : "trash"
          tooltipText: panelContent.clearArmed ? I18n.tr("clipboard.clear-confirm") : I18n.tr("clipboard.clear-history")
          baseSize: Style.baseWidgetSize * 0.8
          colorFg: panelContent.clearArmed ? Color.mError : Color.mOnSurfaceVariant
          enabled: ClipboardService.active && ClipboardService.items.length > 0
          onClicked: {
            if (panelContent.clearArmed) {
              panelContent.clearArmed = false;
              clearTimer.stop();
              ClipboardService.wipeAll();
              panelContent.selectedId = "";
              panelContent.selectedIndex = -1;
              panelContent.previewItem = null;
              panelContent.ensureSelection();
            } else {
              panelContent.clearArmed = true;
              clearTimer.restart();
            }
          }
        }

        NIconButton {
          icon: "settings"
          tooltipText: I18n.tr("clipboard.settings")
          baseSize: Style.baseWidgetSize * 0.8
          colorFg: Color.mOnSurfaceVariant
          onClicked: {
            SettingsPanelService.openToTab(SettingsPanel.Tab.Launcher, 1, root.screen);
            root.close();
          }
        }

        NIconButton {
          icon: "close"
          tooltipText: I18n.tr("common.close")
          baseSize: Style.baseWidgetSize * 0.8
          colorFg: Color.mOnSurfaceVariant
          onClicked: root.close()
        }
      }

      NTextInput {
        id: searchInput
        Layout.fillWidth: true
        placeholderText: I18n.tr("clipboard.search-placeholder")
        inputIconName: "search"
        visible: ClipboardService.active && panelContent.totalCount > 0
        onTextChanged: panelContent.filterText = text
        onAccepted: panelContent.activateSelection(false)
      }

      NTabBar {
        id: categoryBar
        Layout.fillWidth: true
        visible: panelContent.showChips
        tabHeight: Style.toOdd(Style.baseWidgetSize * 0.75)
        spacing: Style.marginXS
        distributeEvenly: true

        Repeater {
          model: panelContent.categories

          NTabButton {
            required property var modelData
            required property int index

            tabIndex: index
            text: modelData.label + " (" + panelContent.categoryCounts[modelData.key] + ")"
            checked: panelContent.category === modelData.key
            pointSize: Style.fontSizeXS
            onClicked: panelContent.category = modelData.key
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.marginM
        visible: panelContent.hasContent

        NBox {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 470 * Style.uiScaleRatio

          NListView {
            id: listView
            anchors.fill: parent
            anchors.margins: Style.marginS
            model: panelContent.filteredItems
            spacing: Style.marginXS
            verticalPolicy: ScrollBar.AsNeeded
            gradientColor: Color.mSurfaceVariant
            delegate: ClipboardItemDelegate {
              item: modelData
              selected: index === panelContent.selectedIndex
              onSelectRequested: panelContent.setSelection(index, false)
              onActivateRequested: panelContent.copyItem(item, false)
              onDeleteRequested: panelContent.deleteItem(item)
            }
          }
        }

        NBox {
          Layout.preferredWidth: 300 * Style.uiScaleRatio
          Layout.fillHeight: true

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.marginS
            spacing: Style.marginS

            Item {
              id: previewContainer
              Layout.fillWidth: true
              Layout.fillHeight: true

              ClipboardPreview {
                anchors.fill: parent
                currentItem: panelContent.previewItem
              }

              NText {
                anchors.centerIn: parent
                width: Math.min(parent.width - Style.margin2L, 220 * Style.uiScaleRatio)
                visible: panelContent.previewItem === null
                text: I18n.tr("clipboard.select-item")
                pointSize: Style.fontSizeS
                color: Color.mOnSurfaceVariant
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }
            }

            NDivider {
              Layout.fillWidth: true
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginXS

              NButton {
                Layout.fillWidth: true
                text: I18n.tr("clipboard.copy")
                enabled: panelContent.previewItem !== null
                onClicked: panelContent.activateSelection(false)
              }

              NButton {
                Layout.fillWidth: true
                visible: ProgramCheckerService.wtypeAvailable
                outlined: true
                text: I18n.tr("clipboard.paste")
                enabled: panelContent.previewItem !== null
                onClicked: panelContent.activateSelection(true)
              }

              NIconButton {
                icon: "trash"
                tooltipText: I18n.tr("clipboard.delete")
                baseSize: Style.baseWidgetSize * 0.8
                colorFg: Color.mOnSurfaceVariant
                enabled: panelContent.previewItem !== null
                onClicked: panelContent.deleteSelection()
              }
            }
          }
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !panelContent.hasContent

        ColumnLayout {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.margin2L, 430 * Style.uiScaleRatio)
          spacing: Style.marginM

          NIcon {
            Layout.alignment: Qt.AlignHCenter
            icon: panelContent.stateIcon
            pointSize: Style.fontSizeXXXL
            color: Color.mOnSurfaceVariant
          }

          NText {
            Layout.fillWidth: true
            text: panelContent.stateTitle
            pointSize: Style.fontSizeL
            font.weight: Style.fontWeightSemiBold
            color: Color.mOnSurface
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          NText {
            Layout.fillWidth: true
            text: panelContent.stateDescription
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          NButton {
            Layout.alignment: Qt.AlignHCenter
            visible: panelContent.showEnable
            text: I18n.tr("clipboard.enable")
            onClicked: {
              Settings.data.appLauncher.enableClipboardHistory = true;
              Qt.callLater(function () {
                ClipboardService.list(160);
                panelContent.ensureSelection();
              });
            }
          }

          NButton {
            Layout.alignment: Qt.AlignHCenter
            visible: !panelContent.showEnable && !ClipboardService.cliphistAvailable
            outlined: true
            text: I18n.tr("clipboard.settings")
            onClicked: {
              SettingsPanelService.openToTab(SettingsPanel.Tab.Launcher, 1, root.screen);
              root.close();
            }
          }
        }
      }

      NText {
        Layout.fillWidth: true
        visible: panelContent.hasContent
        text: I18n.tr("clipboard.hint")
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
}
