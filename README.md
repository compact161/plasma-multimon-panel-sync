# plasma-multimon-panel-sync

Keep KDE Plasma 6 panels in sync across multiple monitors.

Plasma gives every screen its own panels. Change a widget, the order or the
size on one screen and the other screens stay as they were. This tool copies
the panel layout from one screen to the panels at the same position on all
other screens, in one click or one command.

## What it does

- **Per position:** panels are grouped by edge (top, bottom, left, right).
  For each edge, one screen's panel is the source and the panels on the same
  edge of the other screens become copies of it: widgets, their settings,
  order and size. Each panel keeps its own visibility (always visible, dodge
  windows, …).
- **Finds the source by itself:** after every sync it stores a fingerprint of
  each position's layout. On the next run, the panel that differs is the one
  you changed. If several differ, it stops and asks for `--from`.
- **Safe:** stops `plasmashell` while it edits the configuration, keeps a
  backup of every run, and `restore` puts the last one back.
- **Saved layouts:** `profile save NAME` / `profile restore NAME` keep whole
  layouts independent of Plasma's internal panel IDs.
- **GUI and tray:** a small Kirigami window to pick the source and sync, and a
  tray icon that only shows up when the panels are out of sync.
- **Main bottom panel visibility:** optionally pin the visibility of the
  main screen's bottom panel (always visible, auto hide, dodge windows,
  windows go below). It is applied right away without restarting Plasma and
  kept after every sync and profile restore. Stored in
  `~/.config/plasma-panel-sync.json`.
- **Cleanup:** removes orphaned widget shortcuts left behind by Plasma.

Edges that are missing on a screen are not created there.

## Requirements

- KDE Plasma 6 (tested on Arch Linux, Plasma 6.8 on Wayland, three monitors)
- Python 3 with PyGObject (`python-gobject`), `qml6` (Qt 6 declarative tools),
  Kirigami, `kscreen-doctor`
- No other packages; no root access

## Install

```sh
git clone https://github.com/compact161/plasma-multimon-panel-sync.git
cd plasma-multimon-panel-sync
./install.sh              # scripts to ~/.local/bin, menu entry, tray autostart
./install.sh --uninstall
```

The scripts are symlinked, so a `git pull` updates them; restart the tray
(`plasma-panel-tray`) after an update.

## Usage

```sh
plasma-panel-sync                    # detect the changed panel and sync
plasma-panel-sync --from DP-1        # source screen explicitly (output name, number or "main")
plasma-panel-sync --dry-run          # show what would change
plasma-panel-sync status             # screens, panels, differences
plasma-panel-sync restore            # undo the last sync
plasma-panel-sync profile save Work  # save the current layout
plasma-panel-sync profile restore Work
plasma-panel-sync profile list | delete NAME
plasma-panel-sync config --main-bottom dodge  # always | autohide | dodge | below | keep
plasma-panel-ui                      # graphical window
```

A sync restarts `plasmashell`, so the panels disappear for a few seconds.

## Tests

```sh
python3 tests/multi-panel.test.py
```

The tests use synthetic Plasma configurations in their own `HOME` and never
touch the running desktop.

## AI use

Large parts of this project were written with AI coding assistants.
I review and test the results on my own multi-monitor setup, but treat the
code like any third-party code: read it before you rely on it. It edits your
Plasma configuration; the tool keeps a backup, but make your own before the
first run. It comes without warranty (see LICENSE). Commits written with an
assistant carry a `Co-Authored-By` line.

## Licence

MIT (see `LICENSE`). Not affiliated with or endorsed by KDE.
