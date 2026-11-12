pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// VPN connections managed through NetworkManager.
//
// Replaces the network-manager-vpn plugin. The plugin shelled out to
// nm-connection-editor for anything beyond connect/disconnect, and had no way
// to abort an activation that was never going to finish — the only escape was
// to cycle the connection by hand.
//
// Supports OpenVPN and WireGuard profiles: connect, disconnect, cancel an
// in-flight activation, import a .ovpn/.conf file, create a profile from a
// form, modify it, and delete it.
Singleton {
  id: root

  // ---------------------------------------------------------------- state
  // uuid -> { uuid, name, type, device, active, state, autoconnect }
  property var connections: ({})
  property bool refreshing: false
  property bool refreshPending: false
  property string lastError: ""

  // connect / disconnect
  property bool connecting: false
  property string connectingUuid: ""
  property bool disconnecting: false
  property string disconnectingUuid: ""

  // management
  property bool importing: false
  property bool removing: false
  property bool saving: false
  property string managingUuid: ""
  // uuid -> { key: value } from `nmcli connection show uuid <uuid>`
  property var details: ({})
  property bool detailsLoading: false

  readonly property var activeConnections: {
    const list = [];
    for (const uuid in connections) {
      if (connections[uuid].active)
        list.push(connections[uuid]);
    }
    return list;
  }

  readonly property var inactiveConnections: {
    const list = [];
    for (const uuid in connections) {
      if (!connections[uuid].active)
        list.push(connections[uuid]);
    }
    return list;
  }

  readonly property bool hasActiveConnection: activeConnections.length > 0

  // True while any operation owns the service; the UI uses it to disable
  // controls that would race.
  readonly property bool busy: connecting || disconnecting || importing || removing || saving

  readonly property string connectingName: connectingUuid && connections[connectingUuid] ? connections[connectingUuid].name : ""

  // ---------------------------------------------------------------- refresh
  function refresh() {
    if (refreshing) {
      refreshPending = true;
      return;
    }
    refreshing = true;
    lastError = "";
    refreshProcess.running = true;
  }

  function scheduleRefresh(interval) {
    delayedRefreshTimer.interval = interval;
    delayedRefreshTimer.restart();
  }

  // ---------------------------------------------------------------- connect
  function connect(uuid) {
    if (busy || !uuid) {
      return;
    }
    const conn = connections[uuid];
    if (!conn) {
      return;
    }
    connecting = true;
    connectingUuid = uuid;
    lastError = "";
    connectProcess.uuid = uuid;
    connectProcess.name = conn.name;
    connectProcess.running = true;
  }

  function disconnect(uuid) {
    if (busy || !uuid) {
      return;
    }
    const conn = connections[uuid];
    if (!conn) {
      return;
    }
    disconnecting = true;
    disconnectingUuid = uuid;
    lastError = "";
    disconnectProcess.uuid = uuid;
    disconnectProcess.name = conn.name;
    disconnectProcess.running = true;
  }

  function toggle(uuid) {
    const conn = connections[uuid];
    if (!conn) {
      return;
    }
    if (conn.active) {
      disconnect(uuid);
    } else {
      connect(uuid);
    }
  }

  // Abort an activation that is not going to complete.
  //
  // Killing the waiting `nmcli connection up` is not enough on its own:
  // NetworkManager keeps activating the profile in the background, so the
  // connection eventually comes up (or keeps retrying) even though nothing is
  // waiting for it. `connection down` is what actually aborts the activation.
  function cancel() {
    if (!connecting || !connectingUuid) {
      return;
    }
    const uuid = connectingUuid;
    const name = connectingName;
    Logger.i("VPN", "Cancelling activation of " + name);

    connectProcess.running = false;
    connecting = false;
    connectingUuid = "";

    cancelProcess.uuid = uuid;
    cancelProcess.name = name;
    cancelProcess.running = true;
  }

  // ---------------------------------------------------------------- manage
  function remove(uuid) {
    if (busy || !uuid) {
      return;
    }
    const conn = connections[uuid];
    if (!conn) {
      return;
    }
    removing = true;
    managingUuid = uuid;
    lastError = "";
    removeProcess.uuid = uuid;
    removeProcess.name = conn.name;
    removeProcess.running = true;
  }

  // type is "openvpn" or "wireguard" — nmcli derives it from the file, but
  // passing it explicitly gives a clearer error when the file is wrong.
  function importFile(type, path) {
    if (busy || !path) {
      return;
    }
    importing = true;
    lastError = "";
    importProcess.type = type || "openvpn";
    importProcess.path = path;
    importProcess.running = true;
  }

  // spec: { name, type, ... } — see _createCommand for the per-type fields.
  function create(spec) {
    if (busy || !spec || !spec.name) {
      return;
    }
    saving = true;
    lastError = "";
    createProcess.spec = spec;
    createProcess.command = _createCommand(spec);
    createProcess.running = true;
  }

  // key/value are nmcli setting properties, e.g. ("connection.autoconnect","yes")
  // or ("vpn.data","username=me").
  function modify(uuid, key, value) {
    if (busy || !uuid || !key) {
      return;
    }
    saving = true;
    managingUuid = uuid;
    lastError = "";
    modifyProcess.uuid = uuid;
    modifyProcess.key = key;
    modifyProcess.value = value === undefined || value === null ? "" : String(value);
    modifyProcess.running = true;
  }

  // Load the full profile so the editor can show current values.
  function loadDetails(uuid) {
    if (!uuid) {
      return;
    }
    detailsLoading = true;
    detailsProcess.uuid = uuid;
    detailsProcess.running = true;
  }

  function clearDetails() {
    details = ({});
    detailsLoading = false;
  }

  function detailValue(uuid, key, fallback) {
    const d = details[uuid];
    if (d && d[key] !== undefined)
      return d[key];
    return fallback === undefined ? "" : fallback;
  }

  function setConnection(uuid, data) {
    if (!uuid) {
      return;
    }
    const map = Object.assign({}, connections);
    if (map[uuid]) {
      map[uuid] = Object.assign({}, map[uuid], data);
      connections = map;
    }
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: refreshProcess
    running: false
    command: ["nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE,STATE,AUTOCONNECT", "connection", "show"]

    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.split("\n");
        const map = {};
        for (let i = 0; i < lines.length; ++i) {
          const line = lines[i].trim();
          if (!line)
            continue;

          // Fields are colon separated, but the name may itself contain
          // colons, so peel the fixed-width tail off the right instead of
          // splitting from the left.
          const parts = line.split(":");
          if (parts.length < 6)
            continue;
          const autoconnect = parts.pop();
          const state = parts.pop();
          const device = parts.pop();
          const type = parts.pop();
          const uuid = parts.pop();
          const name = parts.join(":");
          if (!uuid || !name)
            continue;
          if (type !== "vpn" && type !== "wireguard")
            continue;

          map[uuid] = {
            "uuid": uuid,
            "name": name,
            "type": type,
            "device": device === "--" ? "" : device,
            "active": state === "activated",
            "state": state,
            "autoconnect": autoconnect === "yes"
          };
        }
        connections = map;
        const pending = refreshPending;
        refreshing = false;
        refreshPending = false;
        if (pending)
          scheduleRefresh(200);
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        const pending = refreshPending;
        refreshing = false;
        refreshPending = false;
        if (text.trim()) {
          lastError = text.split("\n")[0].trim();
          Logger.w("VPN", "Refresh error: " + text);
        }
        if (pending)
          scheduleRefresh(2000);
      }
    }
  }

  Process {
    id: connectProcess
    property string uuid: ""
    property string name: ""
    running: false
    command: ["nmcli", "connection", "up", "uuid", uuid]

    stdout: StdioCollector {
      onStreamFinished: {
        const output = text.trim();
        if (!output || (!output.includes("successfully activated") && !output.includes("Connection successfully")))
          return;
        setConnection(connectProcess.uuid, {
                        "active": true,
                        "state": "activated"
                      });
        connecting = false;
        connectingUuid = "";
        lastError = "";
        Logger.i("VPN", "Connected to " + connectProcess.name);
        ToastService.showNotice(connectProcess.name, I18n.tr("toast.vpn.connected", {
                                                               "name": connectProcess.name
                                                             }), "shield-lock");
        scheduleRefresh(1000);
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        const trimmed = text.trim();
        if (trimmed) {
          lastError = trimmed.split("\n")[0].trim();
          Logger.w("VPN", "Connect error: " + trimmed);
          ToastService.showWarning(connectProcess.name, lastError);
        }
        connecting = false;
        connectingUuid = "";
        scheduleRefresh(500);
      }
    }
  }

  // Aborts the NetworkManager-side activation after cancel().
  Process {
    id: cancelProcess
    property string uuid: ""
    property string name: ""
    running: false
    command: ["nmcli", "connection", "down", "uuid", uuid]

    onExited: (exitCode, _status) => {
      if (exitCode === 0) {
        Logger.i("VPN", "Activation cancelled: " + cancelProcess.name);
        ToastService.showNotice(cancelProcess.name, I18n.tr("toast.vpn.cancelled", {
                                                              "name": cancelProcess.name
                                                            }), "shield-off");
      } else {
        Logger.w("VPN", "Cancel failed for " + cancelProcess.name + " (exit " + exitCode + ")");
      }
      scheduleRefresh(500);
    }
  }

  Process {
    id: disconnectProcess
    property string uuid: ""
    property string name: ""
    running: false
    command: ["nmcli", "connection", "down", "uuid", uuid]

    stdout: StdioCollector {
      onStreamFinished: {
        Logger.i("VPN", "Disconnected from " + disconnectProcess.name);
        setConnection(disconnectProcess.uuid, {
                        "active": false,
                        "device": "",
                        "state": "disconnected"
                      });
        disconnecting = false;
        disconnectingUuid = "";
        lastError = "";
        ToastService.showNotice(disconnectProcess.name, I18n.tr("toast.vpn.disconnected", {
                                                                  "name": disconnectProcess.name
                                                                }), "shield-off");
        scheduleRefresh(1000);
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        const trimmed = text.trim();
        if (trimmed) {
          lastError = trimmed.split("\n")[0].trim();
          Logger.w("VPN", "Disconnect error: " + trimmed);
          ToastService.showWarning(disconnectProcess.name, lastError);
        }
        disconnecting = false;
        disconnectingUuid = "";
      }
    }
  }

  Process {
    id: removeProcess
    property string uuid: ""
    property string name: ""
    running: false
    command: ["nmcli", "connection", "delete", "uuid", uuid]

    onExited: (exitCode, _status) => {
      removing = false;
      managingUuid = "";
      if (exitCode === 0) {
        Logger.i("VPN", "Deleted " + removeProcess.name);
        ToastService.showNotice(removeProcess.name, I18n.tr("toast.vpn.removed", {
                                                              "name": removeProcess.name
                                                            }), "trash");
        const map = Object.assign({}, connections);
        delete map[removeProcess.uuid];
        connections = map;
      } else {
        lastError = I18n.tr("toast.vpn.remove-failed", {
                              "name": removeProcess.name
                            });
        ToastService.showWarning(removeProcess.name, lastError);
      }
      scheduleRefresh(500);
    }
  }

  Process {
    id: importProcess
    property string type: "openvpn"
    property string path: ""
    running: false
    command: ["nmcli", "connection", "import", "type", type, "file", path]

    stdout: StdioCollector {
      onStreamFinished: {
        const out = text.trim();
        if (out)
          Logger.i("VPN", "Import: " + out);
      }
    }

    onExited: (exitCode, _status) => {
      importing = false;
      if (exitCode === 0) {
        ToastService.showNotice(I18n.tr("toast.vpn.imported"), importProcess.path, "download");
      } else {
        lastError = I18n.tr("toast.vpn.import-failed");
        ToastService.showWarning(I18n.tr("toast.vpn.import-failed"), importProcess.path);
      }
      scheduleRefresh(500);
    }
  }

  // Builds the nmcli argument list for create(). Kept as a function so the
  // command can be logged verbatim when something is rejected.
  function _createCommand(spec) {
    const args = ["nmcli", "connection", "add"];
    const autoconnect = spec.autoconnect ? "yes" : "no";

    if (spec.type === "wireguard") {
      args.push("type", "wireguard", "con-name", spec.name);
      args.push("connection.autoconnect", autoconnect);
      if (spec.privateKey)
        args.push("wireguard.private-key", spec.privateKey);
      if (spec.address) {
        args.push("ipv4.method", "manual", "ipv4.addresses", spec.address);
      }
      if (spec.dns)
        args.push("ipv4.dns", spec.dns);
      if (spec.peerPublicKey) {
        args.push("--");
        const peer = "wireguard-peer." + spec.peerPublicKey;
        if (spec.peerEndpoint)
          args.push(peer + ".endpoint", spec.peerEndpoint);
        if (spec.allowedIps)
          args.push(peer + ".allowed-ips", spec.allowedIps);
      }
      return args;
    }

    // OpenVPN
    args.push("type", "vpn", "vpn-type", "openvpn", "con-name", spec.name);
    args.push("connection.autoconnect", autoconnect);
    if (spec.gateway)
      args.push("vpn.data", "remote=" + spec.gateway);
    if (spec.username)
      args.push("+vpn.data", "username=" + spec.username);
    if (spec.password)
      args.push("vpn.secrets", "password=" + spec.password);
    return args;
  }

  Process {
    id: createProcess
    property var spec: ({})
    running: false
    command: []

    onExited: (exitCode, _status) => {
      saving = false;
      if (exitCode === 0) {
        Logger.i("VPN", "Created " + (createProcess.spec.name || ""));
        ToastService.showNotice(createProcess.spec.name || "", I18n.tr("toast.vpn.created"), "plus");
      } else {
        lastError = I18n.tr("toast.vpn.create-failed");
        ToastService.showWarning(createProcess.spec.name || "", lastError);
        Logger.w("VPN", "Create failed: " + createProcess.command.join(" "));
      }
      scheduleRefresh(500);
    }
  }

  Process {
    id: modifyProcess
    property string uuid: ""
    property string key: ""
    property string value: ""
    running: false
    command: ["nmcli", "connection", "modify", "uuid", uuid, key, value]

    onExited: (exitCode, _status) => {
      saving = false;
      managingUuid = "";
      if (exitCode === 0) {
        Logger.i("VPN", "Modified " + modifyProcess.key);
        ToastService.showNotice(I18n.tr("toast.vpn.saved"), modifyProcess.key, "check");
      } else {
        lastError = I18n.tr("toast.vpn.save-failed");
        ToastService.showWarning(I18n.tr("toast.vpn.save-failed"), modifyProcess.key);
        Logger.w("VPN", "Modify failed: " + modifyProcess.command.join(" "));
      }
      scheduleRefresh(500);
    }
  }

  Process {
    id: detailsProcess
    property string uuid: ""
    running: false
    command: ["nmcli", "-t", "connection", "show", "uuid", uuid]

    stdout: StdioCollector {
      onStreamFinished: {
        const map = {};
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; ++i) {
          const line = lines[i];
          if (!line)
            continue;
          const idx = line.indexOf(":");
          if (idx === -1)
            continue;
          map[line.substring(0, idx)] = line.substring(idx + 1);
        }
        const next = Object.assign({}, details);
        next[detailsProcess.uuid] = map;
        details = next;
        detailsLoading = false;
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        detailsLoading = false;
      }
    }
  }

  Timer {
    id: delayedRefreshTimer
    repeat: false
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    Logger.i("VPN", "Service started");
    refresh();
  }
}
