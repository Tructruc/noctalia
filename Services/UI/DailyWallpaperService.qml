pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Fetches one wallpaper per day from a remote source and applies it.
//
// Replaces the "daily-wallpaper" plugin, which had to shell out to
// `qs ipc call wallpaper set` from a separate process tree. Living in the
// core service layer means it can call WallpaperService directly, share the
// wallpaper directory with the rest of the picker, and show up in the normal
// settings UI.
//
// Sources:
//   nasa-apod  NASA Astronomy Picture of the Day, via science.nasa.gov's
//              WordPress API (wp/v2/apod-basic). The legacy
//              api.nasa.gov/planetary/apod endpoint is NOT used: since NASA's
//              site migration it returns the site's own title and logo for
//              every date instead of the actual picture.
//   nasa-iotd  NASA "Image of the Day", scraped from nasa.gov (no API).
//   bing       Bing's daily homepage image, via the HPImageArchive JSON API.
//
// The image lands in the wallpaper directory as
// `daily-<source>-<YYYY-MM-DD>.jpg`, so it appears in the picker like any
// other wallpaper and survives restarts without re-downloading.
Singleton {
  id: root

  // ---------------------------------------------------------------- state
  property bool fetching: false
  property string lastError: ""
  property string lastAppliedPath: ""
  property string lastAppliedDate: ""
  property string lastStatus: ""

  // In-flight request bookkeeping.
  property string _source: ""
  property string _date: ""
  property string _path: ""
  property string _url: ""
  property string _fallbackUrl: ""
  property string _resolving: ""

  readonly property var sources: [
    {
      "key": "nasa-apod",
      "name": "NASA APOD"
    },
    {
      "key": "nasa-iotd",
      "name": "NASA Image of the Day"
    },
    {
      "key": "bing",
      "name": "Bing"
    }
  ]

  readonly property string sourceKey: Settings.data.wallpaper.dailyWallpaperSource || "nasa-apod"

  readonly property string sourceName: {
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].key === sourceKey)
        return sources[i].name;
    }
    return sourceKey;
  }

  // ---------------------------------------------------------------- paths
  function todayString() {
    var d = new Date();
    var m = ("0" + (d.getMonth() + 1)).slice(-2);
    var day = ("0" + d.getDate()).slice(-2);
    return d.getFullYear() + "-" + m + "-" + day;
  }

  function targetDirectory() {
    var configured = (Settings.data.wallpaper.dailyWallpaperDirectory || "").trim();
    var dir = configured.length > 0 ? Settings.preprocessPath(configured) : Settings.preprocessPath(Settings.data.wallpaper.directory);
    if (!dir || dir === "")
      dir = Settings.defaultWallpapersDirectory;
    if (!dir.endsWith("/"))
      dir += "/";
    return dir;
  }

  // Each source needs its own filename. nasa-apod and nasa-iotd are different
  // images, so sharing a "nasa" prefix made one silently reuse the other's
  // file and never fetch.
  function sourcePrefix(source) {
    if (source === "bing")
      return "bing";
    if (source === "nasa-iotd")
      return "iotd";
    return "apod";
  }

  function pathFor(source, date) {
    return targetDirectory() + "daily-" + sourcePrefix(source) + "-" + date + ".jpg";
  }

  // ---------------------------------------------------------------- check
  // Entry point. Called on startup and on the periodic timer.
  function check() {
    if (!Settings.data.wallpaper.enabled || !Settings.data.wallpaper.dailyWallpaperEnabled) {
      return;
    }
    if (fetching) {
      Logger.d("DailyWallpaper", "Skipping check: already fetching");
      return;
    }

    var date = todayString();
    var source = sourceKey;
    var path = pathFor(source, date);

    _source = source;
    _date = date;
    _path = path;

    // Ask the filesystem whether today's image is already here. A Process is
    // used rather than XMLHttpRequest because Qt's XHR does not resolve
    // file:// URLs, which made every check re-download.
    existsProc.command = ["test", "-f", path];
    existsProc.running = true;
  }

  function _onExistsResult(exists) {
    if (!Settings.data.wallpaper.dailyWallpaperEnabled)
      return;

    if (exists) {
      if (lastAppliedDate !== _date || lastAppliedPath !== _path) {
        Logger.i("DailyWallpaper", "Today's wallpaper already downloaded, applying:", _path);
        lastStatus = "Applied " + _path;
        apply(_path, _date);
      } else {
        Logger.d("DailyWallpaper", "Today's wallpaper already applied");
      }
      return;
    }

    fetching = true;
    lastError = "";
    _url = "";
    _fallbackUrl = "";

    Logger.i("DailyWallpaper", "Fetching", sourceName, "for", _date);
    resolveUrl(_source, _date);
  }

  // ---------------------------------------------------------------- resolve
  function resolveUrl(source, date) {
    _resolving = source;

    if (source === "bing") {
      resolveBing();
    } else if (source === "nasa-iotd") {
      resolveNasaIotd();
    } else {
      resolveNasaApod(date);
    }
  }

  function _fail(message) {
    Logger.e("DailyWallpaper", message);
    lastError = message;
    lastStatus = message;
    fetching = false;
    _resolving = "";
  }

  function _succeed(path, date) {
    lastError = "";
    lastStatus = "Applied " + path;
    fetching = false;
    _resolving = "";
    apply(path, date);
  }

  function _beginDownload(url, fallbackUrl) {
    _url = url;
    _fallbackUrl = fallbackUrl || "";
    downloadProc.command = ["sh", "-c", "mkdir -p '" + targetDirectory() + "' && curl -fsSL --max-time 120 -o '" + _path + "' '" + _url + "'"];
    downloadProc.running = true;
  }

  // ---------------------------------------------------------------- bing
  function resolveBing() {
    var locale = (Settings.data.wallpaper.dailyWallpaperLocale || "").trim();
    var market = locale.length > 0 ? locale : "en-US";
    bingProc.command = ["curl", "-fsSL", "--max-time", "30", "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=" + market];
    bingProc.running = true;
  }

  // ---------------------------------------------------------------- nasa apod
  // science.nasa.gov exposes the APOD as a WordPress custom post type. The
  // dated endpoint takes YYMMDD, so ask for exactly today's entry rather than
  // taking the newest item off the list.
  function apodDateKey(date) {
    // date is YYYY-MM-DD
    return date.substring(2, 4) + date.substring(5, 7) + date.substring(8, 10);
  }

  function resolveNasaApod(date) {
    var key = apodDateKey(date || todayString());
    apodProc.command = ["curl", "-fsSL", "--max-time", "30", "https://science.nasa.gov/wp-json/wp/v2/apod-basic/" + key];
    apodProc.running = true;
  }

  // hdurl carries a rendition query (?w=1638&h=2048&fit=clip...). Drop it and
  // ask for a 4K-class rendition instead of the small crop.
  function _apodHiRes(url) {
    if (!url)
      return "";
    var q = url.indexOf("?");
    if (q !== -1)
      url = url.substring(0, q);
    return url + "?w=3840";
  }

  // ---------------------------------------------------------------- nasa iotd
  function resolveNasaIotd() {
    iotdProc.command = ["curl", "-fsSL", "--max-time", "30", "-A", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36", "https://www.nasa.gov/image-of-the-day/"];
    iotdProc.running = true;
  }

  function _nasaIotdPrimary(page) {
    var m = page.match(/<[^>]*class="[^"]*hds-gallery-image[^"]*"[^>]*>[\s\S]*?<img[^>]*src="([^"]+)"/i);
    if (!m)
      m = page.match(/<img[^>]*class="[^"]*hds-gallery-image[^"]*"[^>]*src="([^"]+)"/i);
    return m ? m[1] : "";
  }

  function _nasaIotdFallback(page) {
    var m = page.match(/<meta\s+property="og:image"\s+content="([^"]+)"/i);
    if (!m)
      m = page.match(/<meta\s+name="twitter:image"\s+content="([^"]+)"/i);
    return m ? m[1] : "";
  }

  // ---------------------------------------------------------------- apply
  function apply(path, date) {
    lastAppliedPath = path;
    lastAppliedDate = date || todayString();
    WallpaperService.changeWallpaper(path);
  }

  // ---------------------------------------------------------------- cleanup
  function cleanup() {
    var days = Math.max(1, Settings.data.wallpaper.dailyWallpaperKeepDays || 5);
    cleanupProc.command = ["sh", "-c", "find '" + targetDirectory() + "' -maxdepth 1 -name 'daily-*.jpg' -type f -mtime +" + days + " -delete"];
    cleanupProc.running = true;
  }

  // ---------------------------------------------------------------- helpers
  // ---------------------------------------------------------------- processes
  Process {
    id: existsProc
    running: false
    onExited: (exitCode, _status) => root._onExistsResult(exitCode === 0)
  }

  Process {
    id: bingProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        if (root._resolving !== "bing")
          return;
        var base = "";
        try {
          var parsed = JSON.parse(text);
          base = parsed?.images?.[0]?.urlbase || "";
        } catch (e) {
          root._fail("Bing: could not parse response: " + e);
          return;
        }
        if (!base) {
          root._fail("Bing: no image in response");
          return;
        }
        root._beginDownload("https://www.bing.com" + base + "_UHD.jpg", "https://www.bing.com" + base + "_1920x1080.jpg");
      }
    }
    onExited: (exitCode, _status) => {
      if (root._resolving === "bing" && exitCode !== 0)
        root._fail("Bing: request failed (exit " + exitCode + ")");
    }
  }

  Process {
    id: apodProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        if (root._resolving !== "nasa-apod")
          return;
        var data = null;
        try {
          data = JSON.parse(text);
        } catch (e) {
          root._fail("APOD: could not parse response: " + e);
          return;
        }
        if (!data) {
          root._fail("APOD: empty response");
          return;
        }
        // The dated endpoint returns an array; be tolerant of either shape.
        if (Array.isArray(data))
          data = data.length > 0 ? data[0] : null;
        if (!data) {
          root._fail("APOD: no entry for " + root._date);
          return;
        }
        if (data.code || data.message) {
          root._fail("APOD: " + (data.message || data.code));
          return;
        }
        // Video days carry only a poster still, not the picture itself.
        if (data.media_type && data.media_type !== "image") {
          root.lastStatus = "APOD for " + (data.date || root._date) + " is a " + data.media_type + " — keeping current wallpaper";
          Logger.i("DailyWallpaper", root.lastStatus);
          root.fetching = false;
          root._resolving = "";
          return;
        }
        var url = root._apodHiRes(data.hdurl || "");
        if (!url) {
          root._fail("APOD: no image URL for " + (data.date || root._date));
          return;
        }
        Logger.i("DailyWallpaper", "APOD:", data.title || "(untitled)");
        root._beginDownload(url, "");
      }
    }
    onExited: (exitCode, _status) => {
      if (root._resolving === "nasa-apod" && exitCode !== 0)
        root._fail("APOD: request failed (exit " + exitCode + ")");
    }
  }

  Process {
    id: iotdProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        if (root._resolving !== "nasa-iotd")
          return;
        var page = text || "";
        var primary = root._nasaIotdPrimary(page);
        var fallback = root._nasaIotdFallback(page);
        if (!primary && !fallback) {
          root._fail("NASA Image of the Day: could not find an image on the page");
          return;
        }
        root._beginDownload(primary || fallback, primary ? fallback : "");
      }
    }
    onExited: (exitCode, _status) => {
      if (root._resolving === "nasa-iotd" && exitCode !== 0)
        root._fail("NASA Image of the Day: request failed (exit " + exitCode + ")");
    }
  }

  Process {
    id: downloadProc
    running: false
    onExited: (exitCode, _status) => {
      if (exitCode !== 0) {
        // Retry once with the fallback URL if we have one.
        if (root._fallbackUrl && root._fallbackUrl.length > 0) {
          var fb = root._fallbackUrl;
          root._fallbackUrl = "";
          Logger.w("DailyWallpaper", "Primary download failed, trying fallback");
          root._beginDownload(fb, "");
          return;
        }
        root._fail("Download failed (exit " + exitCode + ") for " + root._url);
        return;
      }
      Logger.i("DailyWallpaper", "Downloaded", root._path);
      root.cleanup();
      root._succeed(root._path, root._date);
    }
  }

  Process {
    id: cleanupProc
    running: false
    onExited: (exitCode, _status) => {
      if (exitCode !== 0)
        Logger.w("DailyWallpaper", "Cleanup exited with", exitCode);
    }
  }

  // ---------------------------------------------------------------- timers
  // Re-check periodically: a long-running session must notice the date roll
  // over, and a failed morning fetch should get another chance.
  Timer {
    interval: 30 * 60 * 1000
    running: Settings.data.wallpaper.enabled && Settings.data.wallpaper.dailyWallpaperEnabled
    repeat: true
    onTriggered: root.check()
  }

  // Give the rest of the shell time to settle before the first network call.
  Timer {
    interval: 12 * 1000
    running: Settings.data.wallpaper.enabled && Settings.data.wallpaper.dailyWallpaperEnabled
    repeat: false
    onTriggered: root.check()
  }

  // React to the user turning it on, so they do not have to wait for a timer.
  Connections {
    target: Settings.data.wallpaper
    function onDailyWallpaperEnabledChanged() {
      if (Settings.data.wallpaper.dailyWallpaperEnabled)
        Qt.callLater(root.check);
    }
    function onDailyWallpaperSourceChanged() {
      if (Settings.data.wallpaper.dailyWallpaperEnabled) {
        // A different source means a different image even on the same day.
        root.lastAppliedDate = "";
        Qt.callLater(root.check);
      }
    }
  }

  Component.onCompleted: {
    Logger.i("DailyWallpaper", "Service started (source:", root.sourceKey + ")");
  }
}
