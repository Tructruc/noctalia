# This fork

The **Noctalia Shell v4** QML tree — the Quickshell-based shell, not the v5
native rewrite — forked from [`noctalia-dev/noctalia`](https://github.com/noctalia-dev/noctalia)
at tag [`v4.7.7`](https://github.com/noctalia-dev/noctalia/tree/v4.7.7)
(commit `3abfa1f`, 2026-05-13).

Branch `v4` is the working branch. Upstream's `main` carries v5, which is a
separate C++/OpenGL rewrite with no Qt dependency and shares nothing with this
tree.

## Why this exists

Noctalia v4 is archived upstream — no fixes, no features. This fork is where
local changes go, and it is the live config: Quickshell reads
`~/.config/quickshell/noctalia-shell/`, which shadows the packaged copy in
`/etc/xdg/quickshell/noctalia-shell/`. Editing a file here and saving it makes
the shell reload, so changes are visible immediately without a build.

## Running it

The shell runs on a locally built `noctalia-qs` (the Quickshell fork), because
the packaged runtime predates the PipeWire use-after-free fix. See
[`Tructruc/noctalia-qs`](https://github.com/Tructruc/noctalia-qs).

```sh
~/.local/bin/qs-patched -c noctalia-shell
```

`~/.local/qs-current` selects which build of the runtime is used.

## Layout

```
shell.qml          entry point
Commons/           shared singletons: Settings, Style, Color, ShellState
Services/          backends: Compositor, Control, Hardware, Media, Networking, UI
Modules/           UI: Bar, Panels, Toast, LockScreen, Desktop, ...
Assets/            icons, fonts, color schemes, i18n
```

`Commons/Settings.qml` is the single source of truth for configuration —
`~/.config/noctalia/settings.json`. `Commons/Style.qml` holds the derived
metrics (bar height, capsule height, radii) that most layout code reads.

## Planned work

Folding plugin functionality into the core tree so it is better integrated than
the plugin API allows:

| Plugin | Lines | Intent |
|---|---|---|
| `keybind-cheatsheet` | ~4,200 | core panel |
| `monitor-layout` | ~1,400 | core panel |
| `network-manager-vpn` | ~950 | merged into the network widget/panel |
| `workspace-overview` | ~330 | core panel |
| `daily-wallpaper` | ~390 | core wallpaper service |

Plugins live in `~/.config/noctalia/plugins/<name>/` and are loaded through
`Services/Plugin/` — the integration work is mostly moving their QML under
`Modules/Panels/` and their state under `Services/`, then wiring IPC through
`Services/Control/IPCService.qml`.

## Upstream

MIT licensed; see `LICENSE`. Everything here is upstream's work except commits
on top of `v4.7.7`.
