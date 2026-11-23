pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Display
import qs.Services.UI

// v4 -> Noctalia Greeter appearance/display sync.
//
// The greeter ships the privileged helper; this service only produces the
// staging directory it accepts, then calls it through pkexec. Nothing here
// depends on Noctalia v5: the protocol is documented by the greeter itself.
Singleton {
  id: root

  readonly property string helperPath: "/usr/bin/noctalia-greeter-apply-appearance"
  readonly property string stateDir: "/var/lib/noctalia-greeter"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string stagingDir: runtimeDir !== "" ? runtimeDir + "/noctalia-greeter-sync" : ""

  property bool helperInstalled: false
  property bool secureSync: false
  property bool greetdActive: false

  property bool syncing: false
  property bool lastSyncOk: false
  property double lastSyncMs: 0
  property string lastError: ""
  property string _syncedSignature: ""
  property string _pendingSignature: ""

  readonly property bool available: helperInstalled && secureSync && stagingDir !== ""

  signal syncFinished(bool ok, string message)

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------
  function refreshStatus() {
    if (!helperProbe.running) {
      helperProbe.output = "";
      helperProbe.running = true;
    }
    if (!dmProbe.running) {
      dmProbe.output = "";
      dmProbe.running = true;
    }
  }

  function payloadSignature(payload) {
    var data = payload || buildSyncPayload();
    var toml = data.toml;
    var firstLine = toml.indexOf("\n");
    if (firstLine >= 0)
      toml = toml.substring(firstLine + 1);

    var files = [];
    for (var i = 0; i < data.files.length; i++) {
      files.push(data.files[i].source + ">" + data.files[i].name);
    }

    return toml + "\n" + files.join("|") + "\n" + data.layout + "\n" + data.transforms + "\n" + data.scales;
  }

  function scheduleAutoSync() {
    if (!autoSync || syncing || !available)
      return;

    var signature = payloadSignature();
    if (signature === _syncedSignature)
      return;

    _pendingSignature = signature;
    autoTimer.restart();
  }

  readonly property bool autoSync: Settings.data.general.greeterSync.autoSync === true

  // ---------------------------------------------------------------------------
  // Value helpers
  // ---------------------------------------------------------------------------
  function hex6(color) {
    if (!color)
      return "#000000";

    var r = Math.max(0, Math.min(255, Math.round(color.r * 255)));
    var g = Math.max(0, Math.min(255, Math.round(color.g * 255)));
    var b = Math.max(0, Math.min(255, Math.round(color.b * 255)));

    function part(value) {
      var text = value.toString(16);
      return text.length < 2 ? "0" + text : text;
    }

    return "#" + part(r) + part(g) + part(b);
  }

  function tomlString(value) {
    return "\"" + String(value === undefined || value === null ? "" : value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
  }

  function shellQuote(value) {
    return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'";
  }

  function sanitizeConnector(name) {
    return String(name || "output").replace(/[^A-Za-z0-9._-]/g, "_");
  }

  function transformToken(transform) {
    switch (Number(transform) || 0) {
    case 0:
      return "normal";
    case 1:
      return "90";
    case 2:
      return "180";
    case 3:
      return "270";
    case 4:
      return "flipped";
    case 5:
      return "flipped-90";
    case 6:
      return "flipped-180";
    case 7:
      return "flipped-270";
    default:
      return "normal";
    }
  }

  function effectiveFillMode() {
    var mode = String(Settings.data.wallpaper.fillMode || "crop");
    if (mode === "tile")
      return "repeat";
    if (["center", "crop", "fit", "stretch", "repeat", "span"].indexOf(mode) === -1)
      return "crop";
    return mode;
  }

  function enabledOutputs() {
    var result = [];
    for (var i = 0; i < DisplayService.outputs.length; i++) {
      var output = DisplayService.outputs[i];
      if (output && output.enabled !== false && output.name)
        result.push(output);
    }
    return result;
  }

  function wallpaperSource(name) {
    var path = "";
    try {
      path = WallpaperService.getWallpaper(name) || "";
    } catch (e) {
      path = "";
    }
    if (path.startsWith("file://"))
      return path.substring(7);
    return path;
  }

  function extensionOf(path) {
    var slash = path.lastIndexOf("/");
    var dot = path.lastIndexOf(".");
    if (dot <= slash || dot === path.length - 1)
      return "";
    return path.substring(dot);
  }

  function planWallpaper(source, stem, files) {
    if (!source)
      return "";

    // v4 represents a solid-color wallpaper as "solid://#rrggbb"; the
    // greeter's contract uses "color:#rrggbb".
    if (source.startsWith("solid://"))
      return "color:" + source.substring(8);
    if (source.startsWith("color:"))
      return source;

    var name = stem + extensionOf(source);
    files.push({
                 "source": source,
                 "name": name
               });
    return stateDir + "/" + name;
  }

  // ---------------------------------------------------------------------------
  // Payload
  // ---------------------------------------------------------------------------
  function buildSyncPayload() {
    var files = [];
    var lines = [];
    var outputs = enabledOutputs();

    lines.push("# Generated by Noctalia v4 greeter sync on " + Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm:ss"));
    lines.push("");
    lines.push("[appearance]");
    lines.push("scheme = \"Synced\"");
    lines.push("theme_mode = " + tomlString(Settings.data.colorSchemes.darkMode === false ? "light" : "dark"));
    lines.push("corner_radius_scale = " + (Math.max(0.0, Math.min(2.0, Number(Settings.data.general.radiusRatio) || 1.0))).toFixed(2));
    lines.push("font_family = " + tomlString(Settings.data.ui.fontDefault || "Sans"));
    lines.push("");
    lines.push("[appearance.palette]");

    var palette = [
          ["primary", Color.mPrimary],
          ["on_primary", Color.mOnPrimary],
          ["secondary", Color.mSecondary],
          ["on_secondary", Color.mOnSecondary],
          ["tertiary", Color.mTertiary],
          ["on_tertiary", Color.mOnTertiary],
          ["error", Color.mError],
          ["on_error", Color.mOnError],
          ["surface", Color.mSurface],
          ["on_surface", Color.mOnSurface],
          ["surface_variant", Color.mSurfaceVariant],
          ["on_surface_variant", Color.mOnSurfaceVariant],
          ["outline", Color.mOutline],
          ["shadow", Color.mShadow],
          ["hover", Color.mHover],
          ["on_hover", Color.mOnHover]
        ];

    for (var p = 0; p < palette.length; p++)
      lines.push(palette[p][0] + " = " + tomlString(hex6(palette[p][1])));

    var wallpaperEnabled = Settings.data.wallpaper.enabled !== false;
    var fillMode = effectiveFillMode();
    var fillColor = hex6(Settings.data.wallpaper.fillColor);

    if (wallpaperEnabled) {
      var fallbackSource = outputs.length > 0 ? wallpaperSource(outputs[0].name) : WallpaperService.defaultWallpaper;
      var fallbackPath = planWallpaper(fallbackSource, "wallpaper", files);

      if (fallbackPath) {
        lines.push("");
        lines.push("[appearance.wallpaper]");
        lines.push("path = " + tomlString(fallbackPath));
        lines.push("fill_mode = " + tomlString(fillMode));
        lines.push("fill_color = " + tomlString(fillColor));
      }

      for (var w = 0; w < outputs.length; w++) {
        var outputName = outputs[w].name;
        var source = wallpaperSource(outputName);
        if (!source)
          continue;

        var installed = planWallpaper(source, "wallpaper-" + sanitizeConnector(outputName), files);
        if (!installed)
          continue;

        lines.push("");
        lines.push("[appearance.wallpapers." + tomlString(outputName) + "]");
        lines.push("path = " + tomlString(installed));
        lines.push("fill_mode = " + tomlString(fillMode));
        lines.push("fill_color = " + tomlString(fillColor));
      }
    }

    // Monitor layout: only meaningful with at least two outputs that do not
    // share the same origin (same rule as the v5 producer).
    var layout = "";
    if (outputs.length >= 2) {
      var sorted = outputs.slice().sort(function (a, b) {
        if (a.x !== b.x)
          return a.x - b.x;
        if (a.y !== b.y)
          return a.y - b.y;
        return String(a.name).localeCompare(String(b.name));
      });

      var sameOrigin = true;
      for (var s = 1; s < sorted.length; s++) {
        if (sorted[s].x !== sorted[0].x || sorted[s].y !== sorted[0].y) {
          sameOrigin = false;
          break;
        }
      }

      if (!sameOrigin) {
        var layoutParts = [];
        for (var l = 0; l < sorted.length; l++)
          layoutParts.push(sorted[l].name + ":" + Math.round(Number(sorted[l].x) || 0) + "," + Math.round(Number(sorted[l].y) || 0));
        layout = layoutParts.join("; ");
      }
    }

    var transformParts = [];
    var scaleParts = [];
    var byName = outputs.slice().sort(function (a, b) {
      return String(a.name).localeCompare(String(b.name));
    });
    for (var o = 0; o < byName.length; o++) {
      transformParts.push(byName[o].name + ":" + transformToken(byName[o].transform));
      var scale = Number(byName[o].scale);
      if (scale > 0)
        scaleParts.push(byName[o].name + ":" + scale.toFixed(3));
    }

    return {
      "toml": lines.join("\n") + "\n",
      "files": files,
      "layout": layout,
      "transforms": transformParts.join("; "),
      "scales": scaleParts.join("; ")
    };
  }

  function buildScript(payload, dryRun) {
    var script = [];
    script.push("set -eu");
    script.push("umask 077");
    script.push("stage=" + shellQuote(stagingDir));
    script.push("rm -rf \"$stage\"");
    script.push("install -d -m 700 \"$stage\"");
    script.push("cat > \"$stage/sync.toml\" <<'NOCTALIA_GREETER_TOML'");
    script.push(payload.toml.replace(/\n$/, ""));
    script.push("NOCTALIA_GREETER_TOML");
    script.push("chmod 600 \"$stage/sync.toml\"");

    if (payload.layout) {
      script.push("printf '%s\\n' " + shellQuote(payload.layout) + " > \"$stage/output_layout\"");
      script.push("chmod 600 \"$stage/output_layout\"");
    }
    if (payload.transforms) {
      script.push("printf '%s\\n' " + shellQuote(payload.transforms) + " > \"$stage/output_transforms\"");
      script.push("chmod 600 \"$stage/output_transforms\"");
    }
    if (payload.scales) {
      script.push("printf '%s\\n' " + shellQuote(payload.scales) + " > \"$stage/output_scales\"");
      script.push("chmod 600 \"$stage/output_scales\"");
    }

    for (var i = 0; i < payload.files.length; i++) {
      var file = payload.files[i];
      script.push("if [ ! -f " + shellQuote(file.source) + " ]; then echo " + shellQuote("missing wallpaper: " + file.source) + " >&2; exit 1; fi");
      script.push("install -m 600 " + shellQuote(file.source) + " " + shellQuote(stagingDir + "/" + file.name));
    }

    if (dryRun) {
      script.push("echo STAGED");
      script.push("exit 0");
    } else {
      script.push("exec pkexec " + shellQuote(helperPath) + " --sync " + shellQuote(stagingDir));
    }

    return script.join("\n") + "\n";
  }

  // ---------------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------------
  function sync(dryRun) {
    if (syncing)
      return false;
    if (!dryRun && !available) {
      lastError = !helperInstalled ? I18n.tr("panels.lock-screen.greeter-helper-missing") : I18n.tr("panels.lock-screen.greeter-helper-old");
      syncFinished(false, lastError);
      return false;
    }
    if (stagingDir === "") {
      lastError = I18n.tr("panels.lock-screen.greeter-no-runtime");
      syncFinished(false, lastError);
      return false;
    }

    var payload = buildSyncPayload();
    var script = buildScript(payload, dryRun === true);

    _pendingSignature = payloadSignature(payload);
    syncing = true;
    lastError = "";
    syncProcess.stdoutText = "";
    syncProcess.stderrText = "";
    syncProcess.dryRun = dryRun === true;
    syncProcess.command = ["sh", "-c", script];
    syncProcess.running = true;
    return true;
  }

  function syncNow() {
    return sync(false);
  }

  // ---------------------------------------------------------------------------
  // Processes
  // ---------------------------------------------------------------------------
  Process {
    id: helperProbe
    running: false
    command: ["sh", "-c", "if [ -x /usr/bin/noctalia-greeter-apply-appearance ]; then echo PRESENT; /usr/bin/noctalia-greeter-apply-appearance --supports secure-sync-v1 2>/dev/null || true; else echo MISSING; fi"]
    property string output: ""

    stdout: SplitParser {
      onRead: function (line) {
        helperProbe.output += line + "\n";
      }
    }

    onExited: function (exitCode) {
      var lines = helperProbe.output.split("\n");
      var installed = false;
      var secure = false;

      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line === "PRESENT")
          installed = true;
        else if (line === "secure-sync-v1")
          secure = true;
      }

      root.helperInstalled = installed;
      root.secureSync = secure;
    }
  }

  Process {
    id: dmProbe
    running: false
    command: ["sh", "-c", "systemctl is-active greetd 2>/dev/null || true"]
    property string output: ""

    stdout: SplitParser {
      onRead: function (line) {
        dmProbe.output += line + "\n";
      }
    }

    onExited: function (exitCode) {
      var lines = dmProbe.output.split("\n");
      root.greetdActive = (lines[0] || "").trim() === "active";
    }
  }

  Process {
    id: syncProcess
    running: false
    property string stdoutText: ""
    property string stderrText: ""
    property bool dryRun: false

    stdout: SplitParser {
      onRead: function (line) {
        syncProcess.stdoutText += line + "\n";
      }
    }

    stderr: SplitParser {
      onRead: function (line) {
        syncProcess.stderrText += line + "\n";
      }
    }

    onExited: function (exitCode) {
      root.syncing = false;
      var out = syncProcess.stdoutText.trim();
      var err = syncProcess.stderrText.trim();
      var ok = exitCode === 0;

      if (ok) {
        root.lastSyncOk = true;
        root.lastSyncMs = Date.now();
        root.lastError = "";
        root._syncedSignature = root._pendingSignature;
        root.syncFinished(true, syncProcess.dryRun ? "staged" : "synced");
      } else {
        root.lastSyncOk = false;
        root.lastError = err !== "" ? err : (out !== "" ? out : "helper exited with code " + exitCode);
        root.syncFinished(false, root.lastError);
      }
    }
  }

  Timer {
    id: autoTimer
    interval: 1500
    repeat: false
    onTriggered: root.sync(false)
  }

  Connections {
    target: WallpaperService
    function onWallpaperChanged(screenName, path) {
      root.scheduleAutoSync();
    }
  }

  Connections {
    target: DisplayService
    function onRevisionChanged() {
      // DisplayService increments its revision on every poll; only a real
      // layout change should trigger an auto-sync.
      if (root._syncedSignature === "")
        return;
      if (root.payloadSignature() !== root._syncedSignature)
        root.scheduleAutoSync();
    }
  }

  Connections {
    target: Settings
    function onSettingsSaved() {
      root.scheduleAutoSync();
    }
  }

  Component.onCompleted: refreshStatus()
}
