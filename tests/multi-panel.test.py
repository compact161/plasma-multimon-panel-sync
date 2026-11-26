#!/usr/bin/env python3
"""Tests for plasma-panel-sync with several panels per screen (synthetic configs,
own HOME, Plasma is not touched):  python3 plasma-panel-sync/tests/multi-panel.test.py"""

import contextlib
import importlib.machinery
import io
import json
import os
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "plasma-panel-sync"
SCREENS = {0: "DP-2", 1: "HDMI-A-1", 2: "DP-1"}


def applets_rc(panels):
    """panels: [(pid, screen, location, widgets, extra_general)]"""
    out = []
    for pid, scr, loc, widgets, extra in panels:
        out += [
            f"[Containments][{pid}]",
            "activityId=",
            "formfactor=2",
            f"lastScreen={scr}",
            f"location={loc}",
            "plugin=org.kde.panel",
            "wallpaperplugin=org.kde.image",
            "",
        ]
        ids = []
        for i, w in enumerate(widgets):
            aid = int(pid) * 100 + i
            ids.append(str(aid))
            out += [
                f"[Containments][{pid}][Applets][{aid}]",
                "immutability=1",
                f"plugin={w}",
                "",
                f"[Containments][{pid}][Applets][{aid}][Configuration]",
                "PreloadWeight=42",
                "",
            ]
        out += [f"[Containments][{pid}][General]", "AppletOrder=" + ";".join(ids)]
        out += [f"{k}={v}" for k, v in extra.items()] + [""]
    return "\n".join(out)


def shell_rc(panels, vis):
    out = []
    for pid, *_ in panels:
        out += [
            f"[PlasmaViews][Panel {pid}]",
            "alignment=132",
            "floating=1",
            f"panelVisibility={vis[pid]}",
            "",
            f"[PlasmaViews][Panel {pid}][Defaults]",
            "thickness=44",
            "",
        ]
    return "\n".join(out)


BASE = [
    ("10", 0, 3, ["org.kde.plasma.digitalclock"], {}),
    ("11", 1, 3, ["org.kde.plasma.digitalclock"], {}),
    ("12", 2, 3, ["org.kde.plasma.digitalclock"], {}),
    ("20", 0, 4, ["org.kde.plasma.kickoff", "org.kde.plasma.icontasks"], {}),
    ("21", 1, 4, ["org.kde.plasma.kickoff", "org.kde.plasma.icontasks"], {}),
    ("22", 2, 4, ["org.kde.plasma.kickoff", "org.kde.plasma.icontasks"], {}),
]
VIS = {"10": 0, "11": 0, "12": 0, "20": 2, "21": 2, "22": 2}


class Args:
    def __init__(self, **kw):
        self.rest, self.force, self.source, self.dry_run = [], False, None, False
        self.main_bottom = None
        self.__dict__.update(kw)


class MultiPanel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = Path(self.tmp.name)
        (home / ".config").mkdir()
        self._env = dict(os.environ)
        os.environ["HOME"] = str(home)
        os.environ.pop("XDG_STATE_HOME", None)
        os.environ.pop("XDG_DATA_HOME", None)
        os.environ["PPS_NO_NOTIFY"] = "1"
        loader = importlib.machinery.SourceFileLoader("pps_test", str(TOOL))
        self.pps = types.ModuleType("pps_test")
        loader.exec_module(self.pps)
        self.pps.plasmashell = lambda action: None  # no Plasma restart
        self.pps.screens = lambda: dict(SCREENS)
        self.pps.outputs = lambda: []
        self.shortcuts = []  # no real KGlobalAccel
        self.pps.shortcut_names = lambda: list(self.shortcuts)
        self.pps.unregister_shortcut = self.shortcuts.remove
        self.calls = []
        self.pps.notify = lambda msg, error=False: self.calls.append((msg, error))
        self.write(BASE, VIS)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self.tmp.cleanup()

    def write(self, panels, vis):
        self.pps.APPLETSRC.write_text(applets_rc(panels))
        self.pps.SHELLRC.write_text(shell_rc(panels, vis))

    def load(self):
        return self.pps.KConfig(self.pps.APPLETSRC), self.pps.KConfig(self.pps.SHELLRC)

    def hashes(self):
        rc, shell = self.load()
        return {pid: self.pps.fingerprint(rc, shell, pid)[0] for pid in self.pps.panels(rc)}

    def vis(self):
        shell = self.pps.KConfig(self.pps.SHELLRC)
        return {
            pid: self.pps.KConfig.kv(shell.find(("PlasmaViews", f"Panel {pid}"))[1])[
                "panelVisibility"
            ]
            for pid in self.pps.panels(self.pps.KConfig(self.pps.APPLETSRC))
        }

    def applet_cfg(self, rc, pid):
        """Configuration lines of a panel's first applet (IDs change on sync)."""
        aid = sorted(self.pps.applet_ids(self.pps.subtree(rc, pid)), key=int)[0]
        return rc.find(("Containments", pid, "Applets", aid, "Configuration"))[1]

    # --- Tests ---------------------------------------------------------------
    def test_groups_by_location(self):
        rc, _ = self.load()
        grp = self.pps.groups(self.pps.panels(rc))
        self.assertEqual(grp, {3: {0: "10", 1: "11", 2: "12"}, 4: {0: "20", 1: "21", 2: "22"}})

    def test_duplicate_location_on_screen_is_rejected(self):
        self.write(BASE + [("30", 0, 4, ["org.kde.plasma.pager"], {})], {**VIS, "30": 0})
        rc, _ = self.load()
        with self.assertRaises(SystemExit):
            self.pps.groups(self.pps.panels(rc))

    def test_initial_sync_from_main_and_snapshot(self):
        panels = list(BASE)
        panels[5] = ("22", 2, 4, ["org.kde.plasma.kickoff"], {})  # DP-1 bottom differs
        self.write(panels, VIS)
        with self.assertRaises(SystemExit):  # no snapshot: --from required
            self.pps.cmd_sync(Args())
        self.pps.cmd_sync(Args(source="main"))
        h = self.hashes()
        self.assertEqual(len({h["20"], h["21"], h["22"]}), 1)
        self.assertEqual(len({h["10"], h["11"], h["12"]}), 1)
        self.assertNotEqual(h["10"], h["20"])  # positions stay different
        snap = json.loads(self.pps.SNAPSHOT.read_text())
        self.assertEqual(set(snap["groups"]), {"3", "4"})
        self.assertEqual(snap["groups"]["4"]["hash"], h["20"])
        rc, _ = self.load()
        self.assertEqual(self.pps.panels(rc)["22"]["screen"], 2)  # target stays on its screen

    def test_sync_prunes_shortcuts_of_replaced_widgets(self):
        panels = list(BASE)
        panels[5] = ("22", 2, 4, ["org.kde.plasma.kickoff"], {})
        self.write(panels, VIS)
        # 2000 = source widget (kept), 2200 = target widget (replaced), 7 = long gone
        self.shortcuts[:] = [
            "activate widget 2000",
            "activate widget 2200",
            "activate widget 7",
            "activate application launcher",
        ]
        self.pps.cmd_sync(Args(source="main"))
        self.assertEqual(self.shortcuts, ["activate widget 2000", "activate application launcher"])

    def test_auto_detects_changed_panel_only_in_its_location(self):
        self.pps.cmd_sync(Args(source="main"))
        before = self.hashes()
        rc, shell = self.load()  # noqa: RUF059
        self.pps.KConfig.set_key(
            rc.find(("Containments", "11", "General"))[1], "AppletOrder", "1100;1100"
        )
        rc.write()
        a = self.pps.analyze(*self.load(), self.pps.panels(self.pps.KConfig(self.pps.APPLETSRC)))
        self.assertEqual(a.changed, ["11"])
        self.assertEqual(a.auto_source, 1)
        self.assertTrue(a.needs_sync)
        self.pps.cmd_sync(Args())
        after = self.hashes()
        self.assertEqual(len({after["10"], after["11"], after["12"]}), 1)
        self.assertEqual(after["10"], after["11"])
        self.assertEqual(after["20"], before["20"])  # bottom panels untouched
        self.assertFalse(self.pps.analyze(*self.load(), self.pps.panels(self.load()[0])).needs_sync)

    def test_visibility_stays_per_panel(self):
        self.pps.cmd_sync(Args(source="main"))
        shell = self.pps.KConfig(self.pps.SHELLRC)
        self.pps.KConfig.set_key(shell.find(("PlasmaViews", "Panel 21"))[1], "panelVisibility", "0")
        shell.write()
        a = self.pps.analyze(*self.load(), self.pps.panels(self.load()[0]))
        self.assertFalse(a.needs_sync)  # visibility is not a change
        before = self.vis()
        self.pps.cmd_sync(Args(source="main"))
        self.assertEqual(self.vis(), before)
        shell = self.pps.KConfig(self.pps.SHELLRC)
        for sub in ("Defaults",):  # only in the main group
            self.assertNotIn(
                "panelVisibility",
                self.pps.KConfig.kv(shell.find(("PlasmaViews", "Panel 21", sub))[1]),
            )

    def test_changes_on_two_screens_same_location_need_from(self):
        self.pps.cmd_sync(Args(source="main"))
        rc, _ = self.load()
        self.pps.KConfig.set_key(
            rc.find(("Containments", "20", "General"))[1], "AppletOrder", "2001;2000"
        )
        self.pps.KConfig.set_key(
            rc.find(("Containments", "21", "General"))[1], "AppletOrder", "2100"
        )
        rc.write()
        a = self.pps.analyze(*self.load(), self.pps.panels(self.load()[0]))
        self.assertEqual(a.ambiguous, [4])
        self.assertIsNone(a.auto_source)
        with self.assertRaises(SystemExit):
            self.pps.cmd_sync(Args())
        self.pps.cmd_sync(Args(source="HDMI-A-1"))
        h = self.hashes()
        self.assertEqual(len({h["20"], h["21"], h["22"]}), 1)

    def test_same_change_everywhere_refreshes_snapshot(self):
        self.pps.cmd_sync(Args(source="main"))
        shell = self.pps.KConfig(self.pps.SHELLRC)
        for pid in ("10", "11", "12"):
            self.pps.KConfig.set_key(
                shell.find(("PlasmaViews", f"Panel {pid}", "Defaults"))[1], "thickness", "30"
            )
        shell.write()
        a = self.pps.analyze(*self.load(), self.pps.panels(self.load()[0]))
        self.assertEqual(a.refresh, [3])
        self.assertFalse(a.needs_sync)
        self.pps.cmd_sync(Args())
        snap = json.loads(self.pps.SNAPSHOT.read_text())
        self.assertEqual(snap["groups"]["3"]["hash"], self.hashes()["10"])

    def test_popup_tab_state_is_ignored(self):
        self.pps.cmd_sync(Args(source="main"))
        rc, _ = self.load()
        self.pps.KConfig.set_key(self.applet_cfg(rc, "12"), "currentTab", "streams")  # e.g. volume
        rc.write()
        a = self.pps.analyze(*self.load(), self.pps.panels(self.load()[0]))
        self.assertEqual(a.changed, [])
        self.assertFalse(a.needs_sync)

    def test_old_snapshot_with_now_ignored_key_still_detects_single_change(self):
        rc, _ = self.load()
        for pid in ("10", "11", "12"):
            self.pps.KConfig.set_key(self.applet_cfg(rc, pid), "currentTab", "streams")
        rc.write()
        self.pps.cmd_sync(Args(source="main"))
        snap = json.loads(self.pps.SNAPSHOT.read_text())
        # snapshot as before the rule: currentTab in the layout, hash computed over it
        layout = snap["groups"]["3"]["layout"]
        key = next(k for k in layout if k.endswith("/Configuration"))
        layout[key]["currentTab"] = "streams"
        snap["groups"]["3"]["hash"] = self.pps.layout_hash(layout)
        self.pps.SNAPSHOT.write_text(json.dumps(snap))
        rc, _ = self.load()
        lines = self.applet_cfg(rc, "12")
        lines[:] = [l for l in lines if not l.startswith("currentTab=")]  # noqa: E741
        self.pps.KConfig.set_key(
            rc.find(("Containments", "11", "General"))[1], "AppletOrder", "1100;1100"
        )
        rc.write()
        a = self.pps.analyze(*self.load(), self.pps.panels(self.load()[0]))
        self.assertEqual(a.changed, ["11"])
        self.assertEqual(a.ambiguous, [])
        diff = self.pps.diff(layout, self.pps.fingerprint(*self.load(), "11")[1])
        self.assertFalse(any("currentTab" in l for l in diff))  # noqa: E741

    def test_missing_location_on_one_screen_is_skipped(self):
        self.write(
            BASE[:5], {k: v for k, v in VIS.items() if k != "22"}
        )  # DP-1 without bottom panel
        self.pps.cmd_sync(Args(source="main"))
        rc, _ = self.load()
        self.assertEqual(set(self.pps.panels(rc)), {"10", "11", "12", "20", "21"})
        h = self.hashes()
        self.assertEqual(h["20"], h["21"])

    def test_profile_save_restore_all_locations(self):
        self.pps.cmd_sync(Args(source="main"))
        self.pps.cmd_profile(Args(rest=["save", "Work"], source="main"))
        meta = json.loads((self.pps.PROFILES / "work" / "meta.json").read_text())
        self.assertEqual(meta["locations"], [3, 4])
        self.assertEqual(set(meta["widgets"]), {"3", "4"})
        self.assertTrue(self.pps.list_profiles()[0]["active"])
        # change everything, then restore the profile
        panels = [(pid, scr, loc, ["org.kde.plasma.pager"], {}) for pid, scr, loc, *_ in BASE]
        self.write(panels, {k: 1 for k in VIS})
        self.assertFalse(self.pps.list_profiles()[0]["active"])
        self.pps.cmd_profile(Args(rest=["restore", "Work"]))
        h = self.hashes()
        self.assertEqual(h["10"], meta["hashes"]["3"])
        self.assertEqual(h["22"], meta["hashes"]["4"])
        self.assertEqual(self.vis()["22"], "1")  # visibility stays per panel
        self.assertTrue(self.pps.list_profiles()[0]["active"])
        rc, _ = self.load()
        self.assertFalse(
            any(
                g[0] and g[0][0] == "Containments" and g[0][1].startswith("PROFILE")
                for g in rc.groups
            )
        )

    def test_json_lists_panels_per_screen(self):
        self.pps.cmd_sync(Args(source="main"))
        self.pps.outputs = lambda: [
            {"name": n, "pos": {"x": i * 1920, "y": 0}, "size": {"width": 1920, "height": 1080}}
            for i, n in SCREENS.items()
        ]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.pps.cmd_json(None)
        st = json.loads(buf.getvalue())
        self.assertEqual([len(s["panels"]) for s in st["screens"]], [2, 2, 2])
        self.assertEqual([p["locationName"] for p in st["screens"][0]["panels"]], ["top", "bottom"])
        self.assertTrue(st["allEqual"])
        self.assertEqual(st["changedCount"], 0)
        self.assertEqual(st["screens"][0]["panels"][1]["visibility"], 2)

    def add_tray(self, pid, children, tray_id=None, after=()):
        """Append a system tray with child applets to panel pid (optionally more widgets after it)."""
        tid = tray_id or int(pid) * 100 + 50
        txt = self.pps.APPLETSRC.read_text()
        txt += f"\n[Containments][{pid}][Applets][{tid}]\nplugin=org.kde.plasma.systemtray\n"
        for cid, plug in children:
            txt += f"\n[Containments][{pid}][Applets][{tid}][Applets][{cid}]\nplugin={plug}\n"
        for aid, plug in after:
            txt += (
                f"\n[Containments][{pid}][Applets][{aid}]\nplugin={plug}\n"
                f"\n[Containments][{pid}][Applets][{aid}][Configuration][General]\nx=1\n"
            )
        self.pps.APPLETSRC.write_text(txt)

    def test_outputs_without_enabled_field(self):
        """Plasma 6.8: kscreen-doctor -j no longer reports "enabled"."""
        import subprocess

        data = {
            "outputs": [
                {"name": "DP-2", "connected": True, "priority": 3},
                {"name": "DP-1", "connected": True, "priority": 1},
                {"name": "HDMI-A-2", "connected": True, "priority": 0},
                {"name": "HDMI-A-1", "connected": True, "priority": 2},
            ]
        }
        loader = importlib.machinery.SourceFileLoader("pps_out", str(TOOL))
        mod = types.ModuleType("pps_out")
        loader.exec_module(mod)
        orig = subprocess.run
        subprocess.run = lambda *a, **k: types.SimpleNamespace(stdout=json.dumps(data))
        try:
            self.assertEqual(mod.screens(), {0: "DP-1", 1: "HDMI-A-1", 2: "DP-2"})
        finally:
            subprocess.run = orig

    def test_tray_children_numbered_after_panel_widgets(self):
        """When cloning, the tray and its children get the highest IDs (otherwise a tray
        entry Plasma adds later collides with a widget loaded after it)."""
        self.add_tray(
            "11",
            [(1160, "org.kde.plasma.volume")],
            tray_id=1150,
            after=[(1199, "org.kde.plasma.pager")],
        )
        self.pps.cmd_sync(Args(source="1"))
        rc, _ = self.load()
        sub = self.pps.subtree(rc, "10")
        nested = self.pps.nested_ids(sub)
        top = [int(i) for i in self.pps.applet_ids(sub) if i not in nested]
        self.assertTrue(nested and max(top) < min(int(i) for i in nested))
        h = self.hashes()
        self.assertEqual(h["10"], h["11"])

    def test_sync_repairs_duplicate_ids_in_source(self):
        """A duplicate ID in the source (tray child = panel widget) must not be copied."""
        self.add_tray("10", [(1000, "org.kde.plasma.dwellclicker")])  # 1000 = digitalclock
        rc, _ = self.load()
        self.assertEqual(list(self.pps.duplicate_ids(rc)), ["1000"])
        self.pps.cmd_sync(Args(source="0"))
        rc, _ = self.load()
        self.assertEqual(self.pps.duplicate_ids(rc), {})
        self.assertIn(("Containments", "10", "Applets", "1000"), [g[0] for g in rc.groups])
        h = self.hashes()
        self.assertEqual(h["10"], h["11"])
        self.assertEqual(h["11"], h["12"])

    def test_fingerprint_ignores_plasma_added_tray_item_ids(self):
        """Plasma adds the same tray entry on every panel with a different ID."""
        for pid, cid in (("10", 1055), ("11", 1199), ("12", 9002)):
            self.add_tray(
                pid,
                [
                    (int(pid) * 100 + 60, "org.kde.plasma.volume"),
                    (cid, "org.kde.plasma.dwellclicker"),
                ],
            )
        h = self.hashes()
        self.assertEqual(h["10"], h["11"])
        self.assertEqual(h["11"], h["12"])

    # --- Fixed visibility for the main bottom panel ---------------------------
    def test_config_main_bottom_offline_and_kept_on_sync(self):
        self.pps.plasma_running = lambda: False
        self.pps.cmd_config(Args(main_bottom="always"))
        self.assertEqual(json.loads(self.pps.SETTINGS.read_text())["mainBottomVisibility"], 0)
        self.assertEqual(self.vis()["20"], "0")  # main bottom set in plasmashellrc
        self.assertEqual(self.vis()["21"], "2")  # others untouched
        # another screen is the source: main bottom is overwritten, setting wins
        self.pps.cmd_sync(Args(source="1"))
        self.assertEqual(self.vis()["20"], "0")
        self.assertEqual(self.vis()["10"], "0")

    def test_config_main_bottom_enforced_on_sync_and_profile(self):
        self.pps.cmd_sync(Args(source="main"))
        self.pps.cmd_profile(Args(rest=["save", "Work"], source="main"))
        self.pps.SETTINGS.write_text('{"mainBottomVisibility": 1}')
        self.pps.cmd_sync(Args(source="main"))
        self.assertEqual(self.vis()["20"], "1")
        self.pps.SETTINGS.write_text('{"mainBottomVisibility": 3}')
        self.pps.cmd_profile(Args(rest=["restore", "Work"]))
        self.assertEqual(self.vis()["20"], "3")
        self.assertEqual(self.vis()["22"], "2")

    def test_config_main_bottom_live_and_keep(self):
        self.pps.plasma_running = lambda: True
        live = []
        self.pps.set_hiding_live = lambda pid, vis: live.append((pid, vis))
        self.pps.cmd_config(Args(main_bottom="dodge"))
        self.assertEqual(live, [("20", 2)])
        self.pps.cmd_config(Args(main_bottom="keep"))
        self.assertIsNone(self.pps.load_settings()["mainBottomVisibility"])
        self.assertEqual(live, [("20", 2)])  # keep changes nothing
        with self.assertRaises(SystemExit):
            self.pps.cmd_config(Args(main_bottom="sometimes"))

    def test_json_contains_settings(self):
        self.pps.SETTINGS.write_text('{"mainBottomVisibility": 2}')
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.pps.cmd_json(Args())
        self.assertEqual(json.loads(buf.getvalue())["settings"], {"mainBottomVisibility": 2})


if __name__ == "__main__":
    unittest.main(verbosity=1)
