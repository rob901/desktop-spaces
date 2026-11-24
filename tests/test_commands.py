"""End-to-end tests of the commands against the fake aerospace / osascript / open."""
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAKES = os.path.join(ROOT, "tests", "fakes")
sys.path.insert(0, ROOT)

from desktops import config  # noqa: E402
from desktops.commands import main  # noqa: E402

VSCODE = "com.microsoft.VSCode"
CHROME = "com.google.Chrome"


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state_file = os.path.join(self.tmp, "fake.json")
        local_state = os.path.join(self.tmp, "Local State")
        with open(local_state, "w") as f:
            json.dump({"profile": {"info_cache": {"Default": {"name": "Personal"},
                                                  "Profile 2": {"name": "Work"}}}}, f)
        self.env = {
            "FAKE_STATE": self.state_file,
            "PATH": FAKES + os.pathsep + os.environ["PATH"],
            "DESKTOPS_HOME": os.path.join(self.tmp, "desktops"),
            "DESKTOP_CHROME_LOCAL_STATE": local_state,
            "DESKTOP_AEROSPACE": os.path.join(FAKES, "aerospace"),
            "DESKTOP_LAUNCH_TIMEOUT": "3",
            "DESKTOP_POLL_INTERVAL": "0.05",
        }
        self.old_env = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        self.write_fake({
            "focused": "dev", "next_id": 100, "pending": [], "log": [],
            "profiles": {"Default": "Personal", "Profile 2": "Work"},
            "apps": {VSCODE: {"app": "Code", "title": "myproject"},
                     "com.tinyspeck.slackmacgap": {"app": "Slack", "title": "Slack"}},
            "windows": [
                {"id": 1, "app": "Google Chrome", "bundle": CHROME, "ws": "dev",
                 "title": "GitHub - Google Chrome - Work", "chrome_title": "GitHub",
                 "urls": ["https://github.com", "http://localhost:3000"]},
                {"id": 2, "app": "Code", "bundle": VSCODE, "ws": "dev", "title": "myproject"},
                {"id": 3, "app": "Slack", "bundle": "com.tinyspeck.slackmacgap", "ws": "comms",
                 "title": "Slack"},
            ],
        })

    def tearDown(self):
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp)

    # helpers
    def write_fake(self, st):
        with open(self.state_file, "w") as f:
            json.dump(st, f)

    def fake(self):
        with open(self.state_file) as f:
            return json.load(f)

    def patch_fake(self, **kw):
        st = self.fake()
        st.update(kw)
        self.write_fake(st)

    def run_cmd(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def ids_on(self, ws):
        return [w["id"] for w in self.fake()["windows"] if w["ws"] == ws]

    # tests
    def test_save_writes_config_and_state(self):
        code, out, err = self.run_cmd("save", "dev")
        self.assertEqual(code, 0, err)
        cfg = config.load_config("dev")
        self.assertEqual(cfg["workspace"], "dev")
        c, v = cfg["windows"]
        self.assertEqual((c["type"], c["profile"], c["profile_name"]), ("chrome", "Profile 2", "Work"))
        self.assertEqual(c["urls"], ["https://github.com", "http://localhost:3000"])
        self.assertEqual((v["bundle_id"], v["title_match"]), (VSCODE, "^myproject$"))
        self.assertEqual(config.load_state("dev")["windows"], [{"id": 1, "index": 0}, {"id": 2, "index": 1}])
        # refuses to overwrite
        code, _, err = self.run_cmd("save", "dev")
        self.assertEqual(code, 1)
        self.assertIn("--force", err)

    def test_save_warns_on_unknown_profile(self):
        st = self.fake()
        st["windows"][0]["title"] = "GitHub - Google Chrome"
        self.write_fake(st)
        code, _, err = self.run_cmd("save", "dev")
        self.assertEqual(code, 0)
        self.assertIn("profile unknown", err)
        self.assertIsNone(config.load_config("dev")["windows"][0]["profile"])

    def test_round_trip_close_then_open(self):
        self.run_cmd("save", "dev")
        code, out, _ = self.run_cmd("close", "dev")
        self.assertEqual(code, 0)
        self.assertEqual(self.ids_on("dev"), [])
        self.patch_fake(focused="other", launch_delay=0.3)  # slow launches

        code, out, err = self.run_cmd("open", "dev")
        self.assertEqual(code, 0, err)
        wins = [w for w in self.fake()["windows"] if w["ws"] == "dev"]
        self.assertEqual([w["bundle"] for w in wins], [CHROME, VSCODE])
        self.assertEqual(wins[0]["urls"], ["https://github.com", "http://localhost:3000"])
        self.assertIn("Work", wins[0]["title"])
        self.assertEqual(self.fake()["focused"], "dev")
        self.assertEqual([e["id"] for e in config.load_state("dev")["windows"]], [w["id"] for w in wins])
        log = self.fake()["log"]
        self.assertIn(["layout", "--window-id", str(wins[0]["id"]), "h_tiles"], log)

    def test_open_when_already_open_just_switches(self):
        self.run_cmd("save", "dev")
        self.patch_fake(focused="x")
        code, out, _ = self.run_cmd("open", "dev")
        self.assertEqual(code, 0)
        self.assertIn("already open", out)
        self.assertEqual(len(self.fake()["windows"]), 3)
        self.assertEqual(self.fake()["focused"], "dev")

    def test_reuse_existing_window_instead_of_launching(self):
        self.run_cmd("save", "dev")
        config.clear_state("dev")  # VS Code window (id 2) is open but unclaimed
        st = self.fake()
        st["windows"] = [w for w in st["windows"] if w["id"] != 1]
        self.write_fake(st)
        code, out, err = self.run_cmd("open", "dev")
        self.assertEqual(code, 0, err)
        self.assertIn("reusing Code", out)
        self.assertEqual([w["app"] for w in self.fake()["windows"]].count("Code"), 1)

    def test_claimed_window_not_reused_by_other_desktop(self):
        # 'comms' claims Slack (id 3); 'chat' also wants Slack, so must launch its own.
        self.run_cmd("save", "comms", "--workspace", "comms")
        cfg = {"name": "chat", "windows": [{"type": "app", "app": "Slack",
                                            "bundle_id": "com.tinyspeck.slackmacgap"}]}
        config.save_config(cfg)
        code, out, err = self.run_cmd("open", "chat")
        self.assertEqual(code, 0, err)
        self.assertIn("launching Slack", out)
        self.assertEqual([w["ws"] for w in self.fake()["windows"] if w["app"] == "Slack"], ["comms", "chat"])

    def test_close_only_touches_own_windows_and_respects_keep(self):
        self.run_cmd("save", "dev")
        cfg = config.load_config("dev")
        cfg["windows"][1]["keep_on_close"] = True
        config.save_config(cfg, force=True)
        code, out, _ = self.run_cmd("close", "dev")
        self.assertEqual(code, 0)
        self.assertEqual(sorted(w["id"] for w in self.fake()["windows"]), [2, 3])
        self.assertIn("kept 1", out)

    def test_stale_state_dropped(self):
        self.run_cmd("save", "dev")
        st = self.fake()
        st["windows"] = [w for w in st["windows"] if w["id"] == 3]
        self.write_fake(st)
        _, out, _ = self.run_cmd("list")
        self.assertRegex(out, r"dev\s+closed")
        code, _, err = self.run_cmd("close", "dev")  # must not try to close dead IDs
        self.assertEqual((code, err), (0, ""))

    def test_chrome_restore_extras_warn(self):
        config.save_config({"name": "r", "windows": [{"type": "chrome", "profile": "Default",
                                                      "urls": ["https://a"]}]})
        self.patch_fake(chrome_extra_windows=2)
        code, _, err = self.run_cmd("open", "r")
        self.assertEqual(code, 0)
        self.assertIn("3 new Google Chrome windows", err)
        [e] = config.load_state("r")["windows"]
        self.assertEqual([w for w in self.fake()["windows"] if w["id"] == e["id"]][0]["urls"], ["https://a"])

    def test_launch_timeout(self):
        os.environ["DESKTOP_LAUNCH_TIMEOUT"] = "0.3"
        config.save_config({"name": "s", "windows": [{"type": "app", "app": "Code", "bundle_id": VSCODE,
                                                      "reuse_existing": False}]})
        self.patch_fake(launch_delay=5)
        code, _, err = self.run_cmd("open", "s")
        self.assertEqual(code, 1)
        self.assertIn("no new window appeared", err)

    def test_stack_joins(self):
        config.save_config({"name": "s", "layout": "v_tiles", "windows": [
            {"type": "app", "app": "Code", "bundle_id": VSCODE},
            {"type": "app", "app": "Slack", "bundle_id": "com.tinyspeck.slackmacgap", "stack": True}]})
        code, _, err = self.run_cmd("open", "s")
        self.assertEqual(code, 0, err)
        self.assertIn(["join-with", "--window-id", "3", "up"], self.fake()["log"])

    def test_list(self):
        self.run_cmd("save", "dev")
        _, out, _ = self.run_cmd("list")
        self.assertRegex(out, r"dev\s+open\s+workspace=dev\s+windows=2")


if __name__ == "__main__":
    unittest.main()
