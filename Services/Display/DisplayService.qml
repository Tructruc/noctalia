pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons

// Single source of truth for monitor layout on Hyprland.
//
// - Reads the live state from `hyprctl -j monitors all` (modes, scale,
//   transform, vrr, mirror, enabled state), not from a config file.
// - Applies rules through `hyprctl eval hl.monitor({...})` (Hyprland 0.57+
//   has no `keyword monitor`; older releases keep working through the same
//   eval because `hl` is available there since 0.55).
// - Verifies the result and reports what the compositor actually did instead
//   of assuming success.
// - Persists to the file the running config really loads (`monitors.lua` for
//   Lua configs, `monitors.conf` for hyprlang configs), and says so when the
//   config does not include it.
Singleton {
  id: root

  // ---------------------------------------------------------------------------
  // Backend
  // ---------------------------------------------------------------------------
  readonly property string compositorName: {
    if ((Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== "")
      return "Hyprland";
    if ((Quickshell.env("NIRI_SOCKET") || "") !== "")
      return "niri";
    if ((Quickshell.env("SWAYSOCK") || "") !== "")
      return "Sway";
    if ((Quickshell.env("MANGO_INSTANCE_SIGNATURE") || "") !== "")
      return "MangoWC";
    var desktop = Quickshell.env("XDG_CURRENT_DESKTOP") || "";
    return desktop !== "" ? desktop : I18n.tr("common.unknown");
  }
  readonly property bool available: compositorName === "Hyprland"

  // ---------------------------------------------------------------------------
  // Live state
  // ---------------------------------------------------------------------------
  property var outputs: []
  property int revision: 0
  property bool loading: false
  property bool applying: false
  property string lastError: ""
  property var applyErrors: []
  property double lastRefreshMs: 0

  // While true a slow poll runs, so external changes (another tool, hotplug
  // without an event) show up instead of leaving a stale panel behind.
  property bool live: false

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string hyprDir: configHome + "/hypr"
  readonly property string luaPath: hyprDir + "/monitors.lua"
  readonly property string confPath: hyprDir + "/monitors.conf"

  property bool configChecked: false
  property bool hasLuaConfig: false
  property bool hasConfConfig: false
  property bool hasLuaMonitors: false
  property bool hasConfMonitors: false
  property bool luaIncludesMonitors: false
  property bool confSourcesMonitors: false

  // Which file the running config can actually load.
  readonly property bool persistsLua: hasLuaConfig || hasLuaMonitors
  readonly property bool persistsConf: !persistsLua || hasConfConfig || hasConfMonitors

  readonly property string persistencePath: persistsLua ? luaPath : confPath
  readonly property bool persistenceWired: {
    if (!configChecked)
      return true; // unknown yet, do not warn prematurely
    if (persistsLua)
      return luaIncludesMonitors;
    return confSourcesMonitors;
  }
  property string lastSavedPath: ""
  property double lastSavedMs: 0

  signal applyFinished(bool ok, string message)
  signal persisted(bool ok, string message)
  signal refreshFailed(string message)

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------
  property var _refreshQueued: false
  property var _rules: []
  property var _ruleNames: []
  property int _ruleIndex: 0
  property string _currentRuleName: ""
  property var _applyErrors: []
  property var _appliedLayout: []
  property bool _appliedPersist: false
  property var _pendingLayout: null
  property var _appliedVerify: null
  property var _queuedPersist: null
  property var _persistLayout: []
  property string _mergeLua: ""
  property string _mergeConf: ""
  property int _pendingSaves: 0
  property var _saveErrors: []

  readonly property string _configProbeScript: [
    "cd \"$1\" 2>/dev/null || exit 0",
    "for f in hyprland.lua hyprland.conf monitors.lua monitors.conf; do [ -f \"$f\" ] && echo \"FILE:$f\"; done",
    "if [ -f hyprland.lua ] && grep -Ev '^[[:space:]]*--' hyprland.lua | grep -Eq 'require.*monitors'; then echo INCLUDE_LUA; fi",
    "if [ -f hyprland.conf ] && grep -Eq '^[[:space:]]*source[[:space:]]*=.*monitors' hyprland.conf; then echo INCLUDE_CONF; fi",
    "true"
  ].join("; ")

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------
  function refresh(force) {
    if (!available)
      return;

    if (loading) {
      _refreshQueued = true;
      return;
    }
    if (applying && force !== true)
      return;

    if (!configChecked && !configProcess.running)
      configProcess.running = true;

    loading = true;
    fetchProcess.accumulatedOutput = "";
    fetchProcess.running = true;
  }

  function scheduleRefresh() {
    if (_refreshTimer.running)
      return;
    _refreshTimer.restart();
  }

  function outputByName(name) {
    for (var i = 0; i < outputs.length; i++) {
      if (outputs[i].name === name)
        return outputs[i];
    }
    return null;
  }

  function parseMonitors(rawText) {
    var data = JSON.parse(rawText);
    var list = [];

    for (var i = 0; i < data.length; i++) {
      var m = data[i];
      if (!m || !m.name)
        continue;

      var scale = Number(m.scale) > 0 ? Number(m.scale) : 1.0;
      var transform = Number(m.transform) || 0;
      var modes = parseModes(m.availableModes || []);
      var currentKey = modeKey(m.width, m.height, m.refreshRate);

      if (modes.length === 0 && m.width > 0)
        modes.push(makeMode(m.width, m.height, m.refreshRate));
      else if (m.width > 0 && !hasMode(modes, currentKey))
        modes.push(makeMode(m.width, m.height, m.refreshRate));

      var logicalWidth = Math.max(1, Math.round((m.width || 0) / scale));
      var logicalHeight = Math.max(1, Math.round((m.height || 0) / scale));
      var swap = transform % 2 === 1;

      list.push({
                  "name": m.name,
                  "description": m.description || "",
                  "make": m.make || "",
                  "model": m.model || "",
                  "serial": m.serial || "",
                  "enabled": m.disabled !== true,
                  "focused": m.focused === true,
                  "width": Number(m.width) || 0,
                  "height": Number(m.height) || 0,
                  "refresh": round2(Number(m.refreshRate) || 0),
                  "scale": scale,
                  "transform": transform,
                  "vrr": m.vrr === true,
                  "x": Number(m.x) || 0,
                  "y": Number(m.y) || 0,
                  "mirror": (m.mirrorOf && m.mirrorOf !== "none") ? m.mirrorOf : "",
                  "logicalWidth": logicalWidth,
                  "logicalHeight": logicalHeight,
                  "footprintWidth": swap ? logicalHeight : logicalWidth,
                  "footprintHeight": swap ? logicalWidth : logicalHeight,
                  "modes": modes,
                  "modeKey": currentKey,
                  "bitdepth": /2101010/.test(m.currentFormat || "") ? 10 : 8,
                  "cm": (m.colorManagementPreset && m.colorManagementPreset !== "srgb") ? m.colorManagementPreset : "",
                  "sdrBrightness": Number(m.sdrBrightness) || 1.0,
                  "sdrSaturation": Number(m.sdrSaturation) || 1.0
                });
    }

    list.sort(function (a, b) {
      return (a.x - b.x) || a.name.localeCompare(b.name);
    });

    return list;
  }

  function parseModes(rawModes) {
    var modes = [];
    for (var i = 0; i < rawModes.length; i++) {
      var raw = String(rawModes[i] || "").replace(/Hz$/, "");
      var parts = raw.split("@");
      if (parts.length !== 2)
        continue;
      var dims = parts[0].split("x");
      if (dims.length !== 2)
        continue;
      var mode = makeMode(parseInt(dims[0]), parseInt(dims[1]), parseFloat(parts[1]));
      if (mode.width > 0 && mode.height > 0 && !hasMode(modes, mode.key))
        modes.push(mode);
    }

    modes.sort(function (a, b) {
      if (b.width !== a.width)
        return b.width - a.width;
      if (b.height !== a.height)
        return b.height - a.height;
      return b.refresh - a.refresh;
    });

    return modes;
  }

  function makeMode(width, height, refresh) {
    var w = Math.round(Number(width) || 0);
    var h = Math.round(Number(height) || 0);
    var r = round2(Number(refresh) || 0);
    return {
      "key": modeKey(w, h, r),
      "width": w,
      "height": h,
      "refresh": r,
      "label": w + "×" + h + (r > 0 ? " @ " + trimNumber(r) : "")
    };
  }

  function hasMode(modes, key) {
    for (var i = 0; i < modes.length; i++) {
      if (modes[i].key === key)
        return true;
    }
    return false;
  }

  function modeKey(width, height, refresh) {
    return Math.round(width) + "x" + Math.round(height) + "@" + trimNumber(round2(refresh));
  }

  // ---------------------------------------------------------------------------
  // Editing helpers (shared with the settings UI)
  // ---------------------------------------------------------------------------
  function round2(value) {
    return Math.round(Number(value || 0) * 100) / 100;
  }

  function trimNumber(value) {
    var number = Number(value || 0);
    if (!isFinite(number))
      return "0";
    return String(Math.round(number * 100) / 100);
  }

  function logicalSize(o) {
    var scale = Number(o.scale) > 0 ? Number(o.scale) : 1.0;
    var width = Math.max(1, Math.round((Number(o.width) || 0) / scale));
    var height = Math.max(1, Math.round((Number(o.height) || 0) / scale));
    var swap = (Number(o.transform) || 0) % 2 === 1;
    return {
      "width": width,
      "height": height,
      "footprintWidth": swap ? height : width,
      "footprintHeight": swap ? width : height
    };
  }

  function signatureOf(o) {
    return [o.name, o.enabled ? 1 : 0, o.width, o.height, round2(o.refresh), round2(o.scale), o.transform, o.vrr ? 1 : 0, Math.round(o.x), Math.round(o.y), o.mirror || ""].join("|");
  }

  function copyLayout(layout) {
    var copy = [];
    for (var i = 0; i < layout.length; i++) {
      var o = layout[i];
      copy.push({
                  "name": o.name,
                  "description": o.description || "",
                  "make": o.make || "",
                  "model": o.model || "",
                  "modelName": o.modelName || o.model || "",
                  "enabled": o.enabled !== false,
                  "focused": o.focused === true,
                  "width": Number(o.width) || 0,
                  "height": Number(o.height) || 0,
                  "refresh": round2(Number(o.refresh) || 0),
                  "scale": Number(o.scale) > 0 ? Number(o.scale) : 1.0,
                  "transform": Number(o.transform) || 0,
                  "vrr": o.vrr === true,
                  "x": Math.round(Number(o.x) || 0),
                  "y": Math.round(Number(o.y) || 0),
                  "mirror": o.mirror || "",
                  "bitdepth": Number(o.bitdepth) || 8,
                  "cm": o.cm || "",
                  "sdrBrightness": Number(o.sdrBrightness) || 1.0,
                  "sdrSaturation": Number(o.sdrSaturation) || 1.0
                });
    }
    return copy;
  }

  // Tidy layout: enabled outputs side by side from the origin, in their
  // current left-to-right order. Disabled outputs keep their coordinates.
  function autoArrange(layout) {
    var result = copyLayout(layout);
    var enabled = [];

    for (var i = 0; i < result.length; i++) {
      if (result[i].enabled)
        enabled.push(result[i]);
    }

    enabled.sort(function (a, b) {
      return (a.x - b.x) || a.name.localeCompare(b.name);
    });

    var cursor = 0;
    for (var j = 0; j < enabled.length; j++) {
      var size = logicalSize(enabled[j]);
      enabled[j].x = cursor;
      enabled[j].y = 0;
      cursor += size.footprintWidth;
    }

    return result;
  }

  function overlaps(layout) {
    var enabled = [];
    for (var i = 0; i < layout.length; i++) {
      if (layout[i].enabled)
        enabled.push(layout[i]);
    }

    var pairs = [];
    for (var a = 0; a < enabled.length; a++) {
      var sa = logicalSize(enabled[a]);
      var ax1 = enabled[a].x;
      var ay1 = enabled[a].y;
      var ax2 = ax1 + sa.footprintWidth;
      var ay2 = ay1 + sa.footprintHeight;
      for (var b = a + 1; b < enabled.length; b++) {
        var sb = logicalSize(enabled[b]);
        var bx1 = enabled[b].x;
        var by1 = enabled[b].y;
        var bx2 = bx1 + sb.footprintWidth;
        var by2 = by1 + sb.footprintHeight;
        if (ax1 < bx2 && bx1 < ax2 && ay1 < by2 && by1 < ay2)
          pairs.push([enabled[a].name, enabled[b].name]);
      }
    }
    return pairs;
  }

  // ---------------------------------------------------------------------------
  // Applying
  // ---------------------------------------------------------------------------
  function validateLayout(layout) {
    var errors = [];
    var enabledCount = 0;

    for (var i = 0; i < layout.length; i++) {
      var o = layout[i];
      if (!o.enabled)
        continue;

      enabledCount++;
      if (o.width <= 0 || o.height <= 0)
        errors.push(o.name + ": no resolution selected");
      if (!(o.scale > 0))
        errors.push(o.name + ": scale must be greater than zero");
      if (o.mirror === o.name)
        errors.push(o.name + ": cannot mirror itself");
      if (o.mirror) {
        var target = outputByName(o.mirror);
        if (!target)
          errors.push(o.name + ": mirror target " + o.mirror + " does not exist");
        else if (!target.enabled)
          errors.push(o.name + ": mirror target " + o.mirror + " is disabled");
      }
    }

    if (enabledCount === 0)
      errors.push(I18n.tr("panels.display.monitors-apply-no-output"));

    return errors;
  }

  function applyLayout(layout, persist) {
    if (!available || applying)
      return false;

    var errors = validateLayout(layout);
    if (errors.length > 0) {
      applyErrors = errors;
      lastError = errors.join("\n");
      applyFinished(false, lastError);
      return false;
    }

    _rules = [];
    _ruleNames = [];
    _ruleIndex = 0;
    _applyErrors = [];
    _appliedLayout = copyLayout(layout);
    _appliedPersist = persist === true;
    _pendingLayout = null;
    _appliedVerify = null;
    applyErrors = [];
    lastError = "";
    applying = true;

    // Enable/configure first, disable afterwards: a mirror target has to be
    // up before the output mirroring it is reconfigured.
    var ordered = [];
    for (var i = 0; i < layout.length; i++) {
      if (layout[i].enabled)
        ordered.push(layout[i]);
    }
    for (var j = 0; j < layout.length; j++) {
      if (!layout[j].enabled)
        ordered.push(layout[j]);
    }

    for (var k = 0; k < ordered.length; k++) {
      _ruleNames.push(ordered[k].name);
      _rules.push(["hyprctl", "eval", buildRule(ordered[k])]);
    }

    if (_rules.length === 0) {
      applying = false;
      return false;
    }

    startNextRule();
    return true;
  }

  function startNextRule() {
    if (_ruleIndex >= _rules.length) {
      finishRules();
      return;
    }

    _currentRuleName = _ruleNames[_ruleIndex];
    applyProcess.command = _rules[_ruleIndex];
    _ruleIndex++;
    applyProcess.running = true;
  }

  function finishRules() {
    if (_applyErrors.length > 0) {
      applying = false;
      applyErrors = _applyErrors.slice();
      lastError = applyErrors.join("\n");
      applyFinished(false, lastError);
      // Show the real state even when the rules failed.
      scheduleRefresh();
      return;
    }

    // Verify against a fresh read: a poll that was already in flight when the
    // rules ran would otherwise report the pre-apply state.
    _appliedVerify = _appliedLayout;
    _pendingLayout = null;
    _verifyTimer.interval = 500;
    _verifyTimer.restart();
  }

  function verifyApplied() {
    var intended = _pendingLayout;
    _pendingLayout = null;
    var errors = [];

    if (intended) {
      for (var i = 0; i < intended.length; i++) {
        var want = intended[i];
        var live = outputByName(want.name);

        if (!live) {
          errors.push(want.name + ": output is no longer present");
          continue;
        }

        if ((want.enabled === true) !== (live.enabled === true)) {
          errors.push(want.name + (want.enabled ? ": could not enable" : ": could not disable"));
          continue;
        }
        if (!want.enabled)
          continue;

        if ((live.mirror || "") !== (want.mirror || "")) {
          errors.push(want.name + ": requested mirror " + (want.mirror || I18n.tr("common.none")) + ", compositor is using " + (live.mirror || I18n.tr("common.none")));
          continue;
        }
        if (want.mirror)
          continue;

        if (live.width !== Math.round(want.width) || live.height !== Math.round(want.height) || Math.abs(live.refresh - want.refresh) > 0.6) {
          errors.push(want.name + ": requested " + modeLabel(want) + ", compositor is using " + modeLabel(live));
        } else if (Math.abs(live.scale - want.scale) > 0.001) {
          errors.push(want.name + ": requested scale " + trimNumber(want.scale) + ", compositor is using " + trimNumber(live.scale));
        } else if (live.x !== Math.round(want.x) || live.y !== Math.round(want.y)) {
          errors.push(want.name + ": requested position " + Math.round(want.x) + "x" + Math.round(want.y) + ", compositor is using " + live.x + "x" + live.y);
        } else if (live.transform !== want.transform) {
          errors.push(want.name + ": requested rotation " + want.transform + ", compositor is using " + live.transform);
        } else if ((live.vrr === true) !== (want.vrr === true)) {
          errors.push(want.name + ": requested VRR " + (want.vrr ? "on" : "off") + ", compositor is using " + (live.vrr ? "on" : "off"));
        }
      }
    }

    applying = false;

    if (errors.length > 0) {
      applyErrors = errors;
      lastError = errors.join("\n");
      applyFinished(false, lastError);
      return;
    }

    applyErrors = [];
    lastError = "";

    if (_appliedPersist) {
      _appliedPersist = false;
      persistLayout(_appliedLayout);
    }

    applyFinished(true, "");
  }

  function clearErrors() {
    applyErrors = [];
    lastError = "";
  }

  function modeLabel(o) {
    return Math.round(Number(o.width) || 0) + "×" + Math.round(Number(o.height) || 0) + " @" + trimNumber(o.refresh) + " Hz";
  }

  function luaQuote(value) {
    return "\"" + String(value === undefined || value === null ? "" : value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
  }

  function buildRule(o) {
    var parts = ["output = " + luaQuote(o.name)];

    if (!o.enabled) {
      parts.push("disabled = true");
      return "hl.monitor({ " + parts.join(", ") + " })";
    }

    parts.push("mode = " + luaQuote(Math.round(o.width) + "x" + Math.round(o.height) + "@" + trimNumber(o.refresh)));
    parts.push("position = " + luaQuote(Math.round(o.x) + "x" + Math.round(o.y)));
    parts.push("scale = " + trimNumber(o.scale));
    parts.push("vrr = " + (o.vrr ? 1 : 0));
    // Always send transform/mirror/bitdepth, even at their defaults: an eval
    // rule is merged into the live output, so an omitted field can leave the
    // previous value in place (normal rotation would never come back).
    parts.push("transform = " + (Number(o.transform) || 0));
    parts.push("mirror = " + luaQuote(o.mirror || ""));
    parts.push("bitdepth = " + (Number(o.bitdepth) === 10 ? 10 : 8));

    if (o.cm) {
      parts.push("cm = " + luaQuote(o.cm));
      if (o.cm === "hdr" || o.cm === "hdredid") {
        parts.push("sdrbrightness = " + trimNumber(o.sdrBrightness || 1.0));
        parts.push("sdrsaturation = " + trimNumber(o.sdrSaturation || 1.0));
      }
    }

    return "hl.monitor({ " + parts.join(", ") + " })";
  }

  // ---------------------------------------------------------------------------
  // Persisting
  // ---------------------------------------------------------------------------
  function buildLuaConfig(layout) {
    var lines = ["-- Generated by Noctalia on " + Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm:ss") + ". Do not edit manually.", ""];

    for (var i = 0; i < layout.length; i++) {
      var o = layout[i];
      var parts = ["    output = " + luaQuote(o.name)];

      if (!o.enabled) {
        parts.push("    disabled = true");
      } else {
        parts.push("    mode = " + luaQuote(Math.round(o.width) + "x" + Math.round(o.height) + "@" + trimNumber(o.refresh)));
        parts.push("    position = " + luaQuote(Math.round(o.x) + "x" + Math.round(o.y)));
        parts.push("    scale = " + trimNumber(o.scale));
        if (o.mirror)
          parts.push("    mirror = " + luaQuote(o.mirror));
        if (Number(o.bitdepth) === 10)
          parts.push("    bitdepth = 10");
        if (o.cm) {
          parts.push("    cm = " + luaQuote(o.cm));
          if (o.cm === "hdr" || o.cm === "hdredid") {
            parts.push("    sdrbrightness = " + trimNumber(o.sdrBrightness || 1.0));
            parts.push("    sdrsaturation = " + trimNumber(o.sdrSaturation || 1.0));
          }
        }
        parts.push("    vrr = " + (o.vrr ? 1 : 0));
        parts.push("    transform = " + (Number(o.transform) || 0));
      }

      lines.push("hl.monitor({");
      lines.push(parts.join(",\n"));
      lines.push("})");
      lines.push("");
    }

    return lines.join("\n");
  }

  function buildConfConfig(layout) {
    var lines = ["# Generated by Noctalia on " + Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm:ss") + ". Do not edit manually.", ""];

    for (var i = 0; i < layout.length; i++) {
      var o = layout[i];

      if (!o.enabled) {
        lines.push("monitor=" + o.name + ",disable");
        continue;
      }

      var line = "monitor=" + o.name + "," + Math.round(o.width) + "x" + Math.round(o.height) + "@" + trimNumber(o.refresh) + "," + Math.round(o.x) + "x" + Math.round(o.y) + "," + trimNumber(o.scale);

      if (o.mirror)
        line += ",mirror," + o.mirror;
      if (Number(o.bitdepth) === 10)
        line += ",bitdepth,10";
      if (o.cm) {
        line += ",cm," + o.cm;
        if (o.cm === "hdr" || o.cm === "hdredid") {
          line += ",sdrbrightness," + trimNumber(o.sdrBrightness || 1.0);
          line += ",sdrsaturation," + trimNumber(o.sdrSaturation || 1.0);
        }
      }
      line += ",vrr," + (o.vrr ? 1 : 0);

      lines.push(line);

      if (Number(o.transform) > 0)
        lines.push("monitor=" + o.name + ",transform," + (Number(o.transform) || 0));
    }

    return lines.join("\n") + "\n";
  }

  function persistLayout(layout) {
    if (!available || !layout || layout.length === 0)
      return false;

    if (!configChecked) {
      _queuedPersist = copyLayout(layout);
      if (!configProcess.running)
        configProcess.running = true;
      return true;
    }

    _persistLayout = copyLayout(layout);
    _mergeLua = "";
    _mergeConf = "";
    lastSavedPath = persistencePath;

    // Read the current files so rules for outputs that are not connected right
    // now (a docked monitor, a projector) survive this write.
    mergeProcess.accumulatedOutput = "";
    mergeProcess.running = true;
    return true;
  }

  function finishPersist() {
    var layout = _persistLayout;
    _persistLayout = [];
    if (!layout || layout.length === 0)
      return;

    var names = [];
    for (var i = 0; i < layout.length; i++)
      names.push(layout[i].name);

    _pendingSaves = 0;
    _saveErrors = [];

    if (persistsLua) {
      _pendingSaves++;
      luaFile.setText(buildLuaConfig(layout) + preservedLuaBlocks(_mergeLua, names));
    }
    if (persistsConf) {
      _pendingSaves++;
      confFile.setText(buildConfConfig(layout) + preservedConfLines(_mergeConf, names));
    }

    _mergeLua = "";
    _mergeConf = "";

    if (_pendingSaves === 0) {
      lastError = I18n.tr("panels.display.monitors-persist-no-target");
      persisted(false, lastError);
    }
  }

  function preservedLuaBlocks(existing, names) {
    if (!existing)
      return "";

    var blocks = [];
    var regex = /hl\.monitor\s*\(\s*\{[\s\S]*?\}\s*\)/g;
    var match;
    while ((match = regex.exec(existing)) !== null) {
      var block = match[0];
      var nameMatch = /output\s*=\s*"([^"]+)"/.exec(block);
      if (!nameMatch)
        continue;
      if (names.indexOf(nameMatch[1]) !== -1)
        continue;
      blocks.push(block);
    }

    return blocks.length > 0 ? "\n" + blocks.join("\n\n") + "\n" : "";
  }

  function preservedConfLines(existing, names) {
    if (!existing)
      return "";

    var lines = existing.split("\n");
    var kept = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.indexOf("monitor=") !== 0)
        continue;
      var name = line.substring(8).split(",")[0].trim();
      if (name === "" || names.indexOf(name) !== -1)
        continue;
      kept.push(line);
    }

    return kept.length > 0 ? "\n" + kept.join("\n") + "\n" : "";
  }

  function saveFinished(ok, path) {
    if (_pendingSaves <= 0)
      return;

    if (!ok)
      _saveErrors.push(path);
    _pendingSaves--;

    if (_pendingSaves > 0)
      return;

    if (_saveErrors.length > 0) {
      lastError = I18n.tr("panels.display.monitors-persist-failed");
      applyErrors = [lastError];
      persisted(false, lastError);
      return;
    }

    lastSavedMs = Date.now();
    persisted(true, persistencePath);
  }

  // ---------------------------------------------------------------------------
  // Processes
  // ---------------------------------------------------------------------------
  Process {
    id: fetchProcess
    running: false
    command: ["hyprctl", "-j", "monitors", "all"]
    property string accumulatedOutput: ""

    stdout: SplitParser {
      onRead: function (line) {
        fetchProcess.accumulatedOutput += line;
      }
    }

    onExited: function (exitCode) {
      var raw = fetchProcess.accumulatedOutput;
      fetchProcess.accumulatedOutput = "";
      root.loading = false;

      if (exitCode !== 0 || raw.trim() === "") {
        root.lastError = I18n.tr("panels.display.monitors-read-failed");
        root.refreshFailed(root.lastError);
        if (root._pendingLayout) {
          root._pendingLayout = null;
          root.applying = false;
          root.applyErrors = [root.lastError];
          root.applyFinished(false, root.lastError);
        }
      } else {
        try {
          root.outputs = root.parseMonitors(raw);
          root.revision++;
          root.lastRefreshMs = Date.now();
          root.lastError = "";
        } catch (e) {
          root.lastError = I18n.tr("panels.display.monitors-parse-failed");
          Logger.e("DisplayService", "Failed to parse hyprctl monitors:", e);
          root.refreshFailed(root.lastError);
        }
      }

      if (root._pendingLayout)
        root.verifyApplied();

      if (root._refreshQueued) {
        root._refreshQueued = false;
        Qt.callLater(root.refresh);
      }
    }
  }

  Process {
    id: applyProcess
    running: false
    property string accumulatedOutput: ""
    property string accumulatedError: ""

    stdout: SplitParser {
      onRead: function (line) {
        applyProcess.accumulatedOutput += line + "\n";
      }
    }

    stderr: SplitParser {
      onRead: function (line) {
        applyProcess.accumulatedError += line + "\n";
      }
    }

    onExited: function (exitCode) {
      var out = applyProcess.accumulatedOutput.trim();
      var err = applyProcess.accumulatedError.trim();
      applyProcess.accumulatedOutput = "";
      applyProcess.accumulatedError = "";

      if (exitCode !== 0)
        root._applyErrors.push(root._currentRuleName + ": " + (err !== "" ? err : out !== "" ? out : "hyprctl exited with code " + exitCode));
      else if (/^error/i.test(out))
        root._applyErrors.push(root._currentRuleName + ": " + out);
      else if (err !== "")
        root._applyErrors.push(root._currentRuleName + ": " + err);

      root.startNextRule();
    }
  }

  Process {
    id: configProcess
    running: false
    command: ["sh", "-c", root._configProbeScript, "sh", root.hyprDir]
    property string accumulatedOutput: ""

    stdout: SplitParser {
      onRead: function (line) {
        configProcess.accumulatedOutput += line + "\n";
      }
    }

    onExited: function (exitCode) {
      var lines = configProcess.accumulatedOutput.split("\n");
      configProcess.accumulatedOutput = "";

      var luaConfig = false;
      var confConfig = false;
      var luaMonitors = false;
      var confMonitors = false;
      var includeLua = false;
      var includeConf = false;

      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line === "FILE:hyprland.lua")
          luaConfig = true;
        else if (line === "FILE:hyprland.conf")
          confConfig = true;
        else if (line === "FILE:monitors.lua")
          luaMonitors = true;
        else if (line === "FILE:monitors.conf")
          confMonitors = true;
        else if (line === "INCLUDE_LUA")
          includeLua = true;
        else if (line === "INCLUDE_CONF")
          includeConf = true;
      }

      root.hasLuaConfig = luaConfig;
      root.hasConfConfig = confConfig;
      root.hasLuaMonitors = luaMonitors;
      root.hasConfMonitors = confMonitors;
      root.luaIncludesMonitors = includeLua;
      root.confSourcesMonitors = includeConf;
      root.configChecked = true;

      if (root._queuedPersist) {
        var queued = root._queuedPersist;
        root._queuedPersist = null;
        root.persistLayout(queued);
      }
    }
  }

  Process {
    id: mergeProcess
    running: false
    command: ["sh", "-c", "echo \"===LUA===\"; cat \"$1\" 2>/dev/null || true; echo \"===CONF===\"; cat \"$2\" 2>/dev/null || true", "sh", root.luaPath, root.confPath]
    property string accumulatedOutput: ""

    stdout: SplitParser {
      onRead: function (line) {
        mergeProcess.accumulatedOutput += line + "\n";
      }
    }

    onExited: function (exitCode) {
      var text = mergeProcess.accumulatedOutput;
      mergeProcess.accumulatedOutput = "";

      var luaIndex = text.indexOf("===LUA===");
      var confIndex = text.indexOf("===CONF===");
      if (luaIndex !== -1 && confIndex !== -1 && confIndex > luaIndex)
        root._mergeLua = text.substring(luaIndex + 9, confIndex);
      if (confIndex !== -1)
        root._mergeConf = text.substring(confIndex + 10);

      root.finishPersist();
    }
  }

  FileView {
    id: luaFile
    path: root.luaPath
    preload: false
    printErrors: false
    watchChanges: false
    atomicWrites: true
    onSaved: root.saveFinished(true, root.luaPath)
    onSaveFailed: root.saveFinished(false, root.luaPath)
  }

  FileView {
    id: confFile
    path: root.confPath
    preload: false
    printErrors: false
    watchChanges: false
    atomicWrites: true
    onSaved: root.saveFinished(true, root.confPath)
    onSaveFailed: root.saveFinished(false, root.confPath)
  }

  // ---------------------------------------------------------------------------
  // Live updates
  // ---------------------------------------------------------------------------
  Timer {
    id: _refreshTimer
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: _verifyTimer
    interval: 500
    repeat: false
    onTriggered: {
      if (root.loading) {
        _verifyTimer.interval = 150;
        _verifyTimer.restart();
        return;
      }
      root._pendingLayout = root._appliedVerify;
      root._appliedVerify = null;
      root.refresh(true);
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.live && root.available
    onTriggered: root.refresh()
  }

  Connections {
    target: typeof Hyprland !== "undefined" ? Hyprland : null
    ignoreUnknownSignals: true

    function onRawEvent(event) {
      var name = event && event.name ? event.name : "";
      if (name === "monitoradded" || name === "monitorremoved" || name === "monitoraddedv2" || name === "monitorremovedv2" || name === "configreloaded")
        root.scheduleRefresh();
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.scheduleRefresh();
    }
  }

  Component.onCompleted: {
    Logger.i("DisplayService", "Compositor:", compositorName, "available:", available);
    if (available)
      refresh();
  }
}
