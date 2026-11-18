pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Tailscale status and control.
//
// Tailscale is not a NetworkManager VPN, so it does not appear in the
// NetworkManager profile list — it has its own daemon and its own state
// machine. This service polls `tailscale status --json` and exposes enough of
// it for a panel: connection state, the node's own address, peers, and exit
// node selection.
//
// `tailscale up|down|set` require privileges unless the login user has been
// made the tailscaled operator:
//
//     sudo tailscale set --operator=$USER
//
// They are tried unprivileged first so an operator grant means no prompt, and
// retried through pkexec on "Access denied" so the session's polkit agent asks
// for authentication instead of the action silently failing.
Singleton {
  id: root

  property bool available: false
  property bool loading: false
  property string lastError: ""

  // Stopped | Starting | Running | NeedsLogin | NoState | Unknown
  property string backendState: "Unknown"

  property string selfHostName: ""
  property var selfIps: []
  property string tailnetName: ""
  property string magicDnsSuffix: ""
  property var health: []
  // [{ name, dnsName, ips, online, os, exitNodeOption, exitNode }]
  property var peers: []

  // Node currently used as exit node, "" when none.
  property string exitNode: ""

  readonly property bool running: backendState === "Running"
  readonly property bool stopped: backendState === "Stopped"
  readonly property bool needsLogin: backendState === "NeedsLogin"

  readonly property string primaryIp: selfIps.length > 0 ? String(selfIps[0]) : ""

  readonly property int onlinePeerCount: {
    let n = 0;
    for (let i = 0; i < peers.length; ++i) {
      if (peers[i].online)
        n++;
    }
    return n;
  }

  readonly property var exitNodeOptions: {
    const list = [];
    for (let i = 0; i < peers.length; ++i) {
      if (peers[i].exitNodeOption)
        list.push(peers[i]);
    }
    return list;
  }

  // ---------------------------------------------------------------- refresh
  function refresh() {
    if (loading)
      return;
    loading = true;
    statusProcess.running = true;
  }

  function _applyStatus(json) {
    const d = json || ({});
    backendState = d.BackendState || "Unknown";
    selfIps = d.TailscaleIPs || [];
    magicDnsSuffix = d.MagicDNSSuffix || "";

    const self = d.Self || ({});
    selfHostName = self.HostName || self.DNSName || "";
    // Self.ExitNode says whether THIS node advertises as an exit node; the
    // node actually in use is the peer flagged ExitNode below.
    exitNode = "";

    const net = d.CurrentTailnet || ({});
    tailnetName = net.Name || "";

    health = d.Health || [];

    const list = [];
    const pmap = d.Peer || ({});
    for (const key in pmap) {
      const p = pmap[key];
      if (!p)
        continue;
      list.push({
                  "name": p.HostName || p.DNSName || key,
                  "dnsName": p.DNSName || "",
                  "ips": p.TailscaleIPs || [],
                  "online": p.Online === true,
                  "os": p.OS || "",
                  "exitNodeOption": p.ExitNodeOption === true,
                  "exitNode": p.ExitNode === true
                });
      // The exit node in use is reported on the peer. Track its IP, which is
      // what `tailscale set --exit-node` accepts and what the picker keys on.
      if (p.ExitNode === true) {
        if (p.TailscaleIPs && p.TailscaleIPs.length > 0)
          exitNode = String(p.TailscaleIPs[0]);
        else
          exitNode = p.DNSName || p.HostName || "";
      }
    }
    list.sort((a, b) => (a.online === b.online ? a.name.localeCompare(b.name) : (a.online ? -1 : 1)));
    peers = list;
  }

  function _fail(message) {
    lastError = message;
    Logger.w("Tailscale", message);
  }

  // ---------------------------------------------------------------- actions
  function up() {
    _run("up");
  }

  function down() {
    _run("down");
  }

  function setExitNode(value) {
    const v = (value === undefined || value === null) ? "" : String(value);
    _run("set", ["--exit-node=" + v]);
  }

  function _run(kind, extra) {
    lastError = "";
    actionProcess.kind = kind;
    actionProcess.extra = extra || [];
    actionProcess.elevated = false;
    // `tailscale set` takes the flag directly; up/down take no arguments.
    actionProcess.command = ["tailscale", kind].concat(actionProcess.extra);
    actionProcess.running = true;
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: statusProcess
    running: false
    command: ["tailscale", "status", "--json"]

    stdout: StdioCollector {
      onStreamFinished: {
        const raw = text.trim();
        if (raw === "") {
          root.loading = false;
          root.available = false;
          return;
        }
        try {
          root._applyStatus(JSON.parse(raw));
          root.available = true;
          root.lastError = "";
        } catch (e) {
          root._fail("Could not parse tailscale status: " + e);
        }
        root.loading = false;
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim())
          root._fail(text.trim().split("\n")[0]);
        root.loading = false;
      }
    }

    onExited: (exitCode, _status) => {
      root.loading = false;
      if (exitCode !== 0 && !root.lastError)
        root._fail("tailscale status exited " + exitCode);
    }
  }

  // Runs the action unprivileged first. tailscaled refuses with "Access
  // denied" unless the login user is its operator, and in that case the call
  // is retried through pkexec, which raises the session's polkit agent
  // (hyprpolkitagent) for authentication. Doing it this way means no password
  // prompt when the operator grant is already in place.
  Process {
    id: actionProcess
    property string kind: ""
    property var extra: []
    property bool elevated: false
    property bool denied: false
    running: false
    command: []

    stdout: StdioCollector {
      onStreamFinished: {
        const out = text.trim();
        if (out)
          Logger.i("Tailscale", actionProcess.kind + ": " + out);
        if (actionProcess.kind === "up" && out.indexOf("http") !== -1)
          root.lastError = out;
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        const err = text.trim();
        if (!err)
          return;
        Logger.w("Tailscale", actionProcess.kind + " (" + (actionProcess.elevated ? "elevated" : "user") + "): " + err);
        if (err.toLowerCase().indexOf("access denied") !== -1) {
          actionProcess.denied = true;
        } else {
          root.lastError = err.split("\n")[0];
        }
      }
    }

    onExited: (exitCode, _status) => {
      if (actionProcess.denied && !actionProcess.elevated) {
        // Retry through pkexec: this is the authentication prompt.
        actionProcess.denied = false;
        actionProcess.elevated = true;
        root.lastError = "";
        actionProcess.command = ["pkexec", "tailscale", actionProcess.kind].concat(actionProcess.extra);
        Qt.callLater(() => actionProcess.running = true);
        return;
      }
      if (actionProcess.denied) {
        // Still denied after elevating: the prompt was dismissed, or no
        // polkit agent is answering.
        root.lastError = I18n.tr("panels.vpn.tailscale-auth-failed");
        actionProcess.denied = false;
      }
      actionProcess.elevated = false;
      // Re-read state either way: a failed `up` may still have changed it.
      root.refresh();
    }
  }

  Timer {
    // Cheap poll so the panel reflects changes made elsewhere (another
    // machine bringing the tailnet down, an exit node being set by hand).
    interval: 15000
    running: root.available && root.running
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    Logger.i("Tailscale", "Service started");
    refresh();
  }
}
