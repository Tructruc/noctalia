import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.Networking
import qs.Widgets

// VPN profile management: list, connect, cancel, import, create, edit, delete.
// Replaces the network-manager-vpn plugin, which delegated anything beyond
// connect/disconnect to nm-connection-editor and could not abort an
// activation that was never going to finish.
ColumnLayout {
  id: root
  spacing: Style.marginL
  Layout.fillWidth: true

  property string editingUuid: ""
  property bool creating: false
  property string pendingDeleteUuid: ""
  property string formError: ""

  // Create-form state
  property string newType: "openvpn"
  property string newName: ""
  property string newGateway: ""
  property string newUsername: ""
  property string newPassword: ""
  property string newPrivateKey: ""
  property string newAddress: ""
  property string newPeerKey: ""
  property string newPeerEndpoint: ""
  property string newAllowedIps: "0.0.0.0/0"
  property bool newAutoconnect: false

  function resetForm() {
    newType = "openvpn";
    newName = "";
    newGateway = "";
    newUsername = "";
    newPassword = "";
    newPrivateKey = "";
    newAddress = "";
    newPeerKey = "";
    newPeerEndpoint = "";
    newAllowedIps = "0.0.0.0/0";
    newAutoconnect = false;
    formError = "";
  }

  function beginCreate() {
    editingUuid = "";
    creating = true;
    resetForm();
  }

  function beginEdit(uuid) {
    creating = false;
    editingUuid = uuid;
    formError = "";
    VPNService.loadDetails(uuid);
  }

  function closeForm() {
    creating = false;
    editingUuid = "";
    formError = "";
    VPNService.clearDetails();
  }

  function submitCreate() {
    if (newName.trim() === "") {
      formError = I18n.tr("panels.vpn.name") + " is required";
      return;
    }
    if (newType === "openvpn" && newGateway.trim() === "") {
      formError = I18n.tr("panels.vpn.gateway") + " is required";
      return;
    }
    formError = "";
    VPNService.create({
                        "type": newType,
                        "name": newName.trim(),
                        "gateway": newGateway.trim(),
                        "username": newUsername.trim(),
                        "password": newPassword,
                        "privateKey": newPrivateKey.trim(),
                        "address": newAddress.trim(),
                        "peerPublicKey": newPeerKey.trim(),
                        "peerEndpoint": newPeerEndpoint.trim(),
                        "allowedIps": newAllowedIps.trim(),
                        "autoconnect": newAutoconnect
                      });
    closeForm();
  }

  function submitEdit() {
    if (editingUuid === "")
      return;
    const d = VPNService.details[editingUuid] || ({});
    const currentName = d["connection.id"] || "";
    const currentAuto = d["connection.autoconnect"] === "yes";
    if (newName.trim() !== "" && newName.trim() !== currentName)
      VPNService.modify(editingUuid, "connection.id", newName.trim());
    if (newAutoconnect !== currentAuto)
      VPNService.modify(editingUuid, "connection.autoconnect", newAutoconnect ? "yes" : "no");
    if (newUsername.trim() !== "" && newUsername.trim() !== (d["vpn.data.username"] || ""))
      VPNService.modify(editingUuid, "+vpn.data", "username=" + newUsername.trim());
    if (newPassword !== "")
      VPNService.modify(editingUuid, "vpn.secrets", "password=" + newPassword);
    closeForm();
  }

  // ---------------------------------------------------------------- header
  NLabel {
    label: I18n.tr("panels.vpn.title")
    description: I18n.tr("panels.vpn.description")
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginM

    NButton {
      text: I18n.tr("panels.vpn.import")
      icon: "download"
      tooltipText: I18n.tr("panels.vpn.import-tooltip")
      enabled: !VPNService.busy
      onClicked: filePicker.visible = true
    }

    NButton {
      text: I18n.tr("panels.vpn.create")
      icon: "plus"
      tooltipText: I18n.tr("panels.vpn.create-tooltip")
      outlined: true
      enabled: !VPNService.busy
      onClicked: root.beginCreate()
    }

    Item {
      Layout.fillWidth: true
    }

    NLabel {
      visible: VPNService.lastError !== ""
      label: VPNService.lastError
      labelSize: Style.fontSizeS
    }
  }

  NDivider {
    Layout.fillWidth: true
  }

  // ---------------------------------------------------------------- create form
  NBox {
    visible: root.creating
    Layout.fillWidth: true
    Layout.preferredHeight: createCol.implicitHeight + Style.margin2L
    color: Color.mSurface

    ColumnLayout {
      id: createCol
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginM

      NLabel {
        label: I18n.tr("panels.vpn.create")
      }

      NComboBox {
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.type")
        description: I18n.tr("panels.vpn.type-desc")
        model: [
          {
            "key": "openvpn",
            "name": "OpenVPN"
          },
          {
            "key": "wireguard",
            "name": "WireGuard"
          }
        ]
        currentKey: root.newType
        onSelected: key => root.newType = key
      }

      NTextInput {
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.name")
        description: I18n.tr("panels.vpn.name-desc")
        text: root.newName
        onTextChanged: root.newName = text
      }

      // OpenVPN fields
      NTextInput {
        visible: root.newType === "openvpn"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.gateway")
        description: I18n.tr("panels.vpn.gateway-desc")
        text: root.newGateway
        onTextChanged: root.newGateway = text
      }

      NTextInput {
        visible: root.newType === "openvpn"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.username")
        description: I18n.tr("panels.vpn.username-desc")
        text: root.newUsername
        onTextChanged: root.newUsername = text
      }

      NTextInput {
        visible: root.newType === "openvpn"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.password")
        description: I18n.tr("panels.vpn.password-desc")
        text: root.newPassword
        onTextChanged: root.newPassword = text
      }

      // WireGuard fields
      NTextInput {
        visible: root.newType === "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.private-key")
        description: I18n.tr("panels.vpn.private-key-desc")
        text: root.newPrivateKey
        onTextChanged: root.newPrivateKey = text
      }

      NTextInput {
        visible: root.newType === "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.address")
        description: I18n.tr("panels.vpn.address-desc")
        text: root.newAddress
        onTextChanged: root.newAddress = text
      }

      NTextInput {
        visible: root.newType === "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.peer-public-key")
        description: I18n.tr("panels.vpn.peer-public-key-desc")
        text: root.newPeerKey
        onTextChanged: root.newPeerKey = text
      }

      NTextInput {
        visible: root.newType === "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.peer-endpoint")
        description: I18n.tr("panels.vpn.peer-endpoint-desc")
        text: root.newPeerEndpoint
        onTextChanged: root.newPeerEndpoint = text
      }

      NTextInput {
        visible: root.newType === "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.allowed-ips")
        description: I18n.tr("panels.vpn.allowed-ips-desc")
        text: root.newAllowedIps
        onTextChanged: root.newAllowedIps = text
      }

      NToggle {
        label: I18n.tr("panels.vpn.autoconnect")
        description: I18n.tr("panels.vpn.autoconnect-desc")
        checked: root.newAutoconnect
        onToggled: checked => root.newAutoconnect = checked
      }

      NLabel {
        visible: root.formError !== ""
        label: root.formError
        labelSize: Style.fontSizeS
      }

      RowLayout {
        spacing: Style.marginM
        NButton {
          text: I18n.tr("panels.vpn.save")
          icon: "check"
          enabled: !VPNService.busy
          onClicked: root.submitCreate()
        }
        NButton {
          text: I18n.tr("panels.vpn.cancel-edit")
          outlined: true
          onClicked: root.closeForm()
        }
      }
    }
  }

  // ---------------------------------------------------------------- edit form
  NBox {
    visible: root.editingUuid !== ""
    Layout.fillWidth: true
    Layout.preferredHeight: editCol.implicitHeight + Style.margin2L
    color: Color.mSurface

    ColumnLayout {
      id: editCol
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginM

      NLabel {
        label: I18n.tr("panels.vpn.edit")
      }

      NLabel {
        visible: VPNService.detailsLoading
        label: "…"
        labelSize: Style.fontSizeS
      }

      NTextInput {
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.name")
        description: I18n.tr("panels.vpn.name-desc")
        text: root.newName !== "" ? root.newName : VPNService.detailValue(root.editingUuid, "connection.id", "")
        onTextChanged: root.newName = text
      }

      NTextInput {
        visible: VPNService.detailValue(root.editingUuid, "connection.type", "") !== "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.username")
        description: I18n.tr("panels.vpn.username-desc")
        text: root.newUsername !== "" ? root.newUsername : VPNService.detailValue(root.editingUuid, "vpn.data.username", "")
        onTextChanged: root.newUsername = text
      }

      NTextInput {
        visible: VPNService.detailValue(root.editingUuid, "connection.type", "") !== "wireguard"
        Layout.fillWidth: true
        label: I18n.tr("panels.vpn.password")
        description: I18n.tr("panels.vpn.password-desc")
        text: root.newPassword
        onTextChanged: root.newPassword = text
      }

      NToggle {
        label: I18n.tr("panels.vpn.autoconnect")
        description: I18n.tr("panels.vpn.autoconnect-desc")
        checked: root.newAutoconnect
        onToggled: checked => root.newAutoconnect = checked
      }

      RowLayout {
        spacing: Style.marginM
        NButton {
          text: I18n.tr("panels.vpn.save")
          icon: "check"
          enabled: !VPNService.busy
          onClicked: root.submitEdit()
        }
        NButton {
          text: I18n.tr("panels.vpn.cancel-edit")
          outlined: true
          onClicked: root.closeForm()
        }
      }
    }
  }

  // ---------------------------------------------------------------- list
  NLabel {
    visible: Object.keys(VPNService.connections).length === 0
    label: I18n.tr("panels.vpn.empty")
    labelSize: Style.fontSizeS
  }

  Repeater {
    model: {
      const list = [];
      for (const uuid in VPNService.connections)
        list.push(VPNService.connections[uuid]);
      list.sort((a, b) => (b.active === a.active ? a.name.localeCompare(b.name) : (b.active ? 1 : -1)));
      return list;
    }

    delegate: NBox {
      required property var modelData
      readonly property bool isActive: modelData.active
      readonly property bool isConnecting: VPNService.connectingUuid === modelData.uuid
      readonly property bool isDisconnecting: VPNService.disconnectingUuid === modelData.uuid

      Layout.fillWidth: true
      Layout.preferredHeight: rowCol.implicitHeight + Style.margin2L
      color: Color.mSurface

      ColumnLayout {
        id: rowCol
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginS

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.marginM

          NIcon {
            icon: isActive ? "shield-lock" : "shield"
            pointSize: Style.fontSizeL
            color: isActive ? Color.mPrimary : Color.mOnSurfaceVariant
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            NLabel {
              label: modelData.name
              labelSize: Style.fontSizeM
            }

            NLabel {
              label: isConnecting ? I18n.tr("panels.vpn.connecting") : (isDisconnecting ? I18n.tr("panels.vpn.disconnecting") : (isActive ? I18n.tr("panels.vpn.connected") : I18n.tr("panels.vpn.available") + " · " + modelData.type))
              labelSize: Style.fontSizeXS
            }
          }

          // Cancel takes precedence while an activation is in flight: this is
          // the escape hatch the plugin never had.
          NButton {
            visible: isConnecting
            text: I18n.tr("panels.vpn.cancel")
            icon: "x"
            tooltipText: I18n.tr("panels.vpn.cancel-tooltip")
            onClicked: VPNService.cancel()
          }

          NButton {
            visible: !isConnecting
            text: isActive ? I18n.tr("panels.vpn.disconnect") : I18n.tr("panels.vpn.connect")
            icon: isActive ? "plug-off" : "plug"
            outlined: !isActive
            enabled: !VPNService.busy || isDisconnecting
            onClicked: VPNService.toggle(modelData.uuid)
          }

          NIconButton {
            icon: "pencil"
            tooltipText: I18n.tr("panels.vpn.edit")
            baseSize: Style.baseWidgetSize * 0.8
            enabled: !VPNService.busy
            onClicked: root.beginEdit(modelData.uuid)
          }

          NIconButton {
            icon: "trash"
            tooltipText: I18n.tr("panels.vpn.delete")
            baseSize: Style.baseWidgetSize * 0.8
            enabled: !VPNService.busy
            onClicked: root.pendingDeleteUuid = (root.pendingDeleteUuid === modelData.uuid ? "" : modelData.uuid)
          }
        }

        // Inline delete confirmation — deleting a profile is not reversible.
        RowLayout {
          visible: root.pendingDeleteUuid === modelData.uuid
          Layout.fillWidth: true
          spacing: Style.marginM

          NLabel {
            Layout.fillWidth: true
            label: I18n.tr("panels.vpn.delete-confirm", {
                             "name": modelData.name
                           })
            labelSize: Style.fontSizeS
          }

          NButton {
            text: I18n.tr("panels.vpn.delete")
            icon: "trash"
            enabled: !VPNService.busy
            onClicked: {
              VPNService.remove(modelData.uuid);
              root.pendingDeleteUuid = "";
            }
          }

          NButton {
            text: I18n.tr("panels.vpn.cancel-edit")
            outlined: true
            onClicked: root.pendingDeleteUuid = ""
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- picker
  NFilePicker {
    id: filePicker
    visible: false
    title: I18n.tr("panels.vpn.import")
    selectionMode: "files"
    nameFilters: ["*.ovpn", "*.conf", "*.ovpn.conf"]
    showHiddenFiles: false
    onAccepted: paths => {
                  visible = false;
                  if (paths && paths.length > 0) {
                    const p = String(paths[0]);
                    // .ovpn is always OpenVPN; a bare .conf is WireGuard.
                    const type = p.toLowerCase().endsWith(".ovpn") ? "openvpn" : "wireguard";
                    VPNService.importFile(type, p);
                  }
                }
    onCancelled: visible = false
  }
}
