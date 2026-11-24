import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from desktops import aero, chrome, config  # noqa: E402


class ParseWindows(unittest.TestCase):
    def test_json(self):
        text = json.dumps([{"window-id": 7, "app-name": "Code", "app-bundle-id": "com.microsoft.VSCode",
                            "workspace": "dev", "window-title": "a | b"}])
        [w] = aero.parse_windows_json(text)
        self.assertEqual((w.id, w.app, w.bundle_id, w.workspace, w.title),
                         (7, "Code", "com.microsoft.VSCode", "dev", "a | b"))

    def test_format_keeps_pipes_in_title(self):
        [w] = aero.parse_windows_format("7|Code|com.x|dev|a | b | c\n\n")
        self.assertEqual(w.title, "a | b | c")
        self.assertEqual(w.id, 7)


class ChromeMatching(unittest.TestCase):
    def test_exact_before_prefix(self):
        chrome_wins = [("GitHub", []), ("GitHub - PR", [])]
        aero_titles = ["GitHub - PR - Google Chrome - Work", "GitHub"]
        self.assertEqual(chrome.match_windows(aero_titles, chrome_wins), [1, 0])

    def test_suffix_and_duplicates(self):
        chrome_wins = [("Inbox", ["a"]), ("Inbox", ["b"])]
        aero_titles = ["Inbox - Google Chrome - Work", "Inbox - Google Chrome - Home"]
        self.assertEqual(chrome.match_windows(aero_titles, chrome_wins), [0, 1])

    def test_no_match(self):
        self.assertEqual(chrome.match_windows(["Zed"], [("Other", [])]), [None])

    def test_parse_capture(self):
        text = "T1\x1fhttps://a\x1fhttps://b\x1eT2\x1f\x1e\n"
        self.assertEqual(chrome.parse_capture(text), [("T1", ["https://a", "https://b"]), ("T2", [])])


class Profiles(unittest.TestCase):
    profiles = {"Default": "Personal", "Profile 2": "Work", "Profile 3": "Work 2"}

    def test_detect_from_suffix(self):
        self.assertEqual(chrome.detect_profile("X - Google Chrome - Work", self.profiles), "Profile 2")
        self.assertEqual(chrome.detect_profile("X - Google Chrome - Work 2", self.profiles), "Profile 3")

    def test_unknown(self):
        self.assertIsNone(chrome.detect_profile("X - Google Chrome", self.profiles))

    def test_single_profile_fallback(self):
        self.assertEqual(chrome.detect_profile("X", {"Default": "Me"}), "Default")

    def test_local_state(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"profile": {"info_cache": {"Profile 2": {"name": "Work"}}}}, f)
        try:
            self.assertEqual(chrome.load_profiles(f.name), {"Profile 2": "Work"})
        finally:
            os.remove(f.name)


class Config(unittest.TestCase):
    def test_validate(self):
        good = {"name": "dev", "windows": [{"type": "chrome", "urls": []},
                                           {"type": "app", "bundle_id": "com.x"}]}
        self.assertEqual(config.validate(good), [])
        bad = {"name": "a b", "layout": "grid",
               "windows": [{"type": "x"}, {"type": "app"}, {"type": "app", "app": "Y", "title_match": "("}]}
        errs = config.validate(bad)
        self.assertEqual(len(errs), 7, errs)

    def test_prune(self):
        st = {"windows": [{"id": 1, "index": 0}, {"id": 2, "index": 1}]}
        self.assertEqual(config.prune_state(st, {2, 3})["windows"], [{"id": 2, "index": 1}])


if __name__ == "__main__":
    unittest.main()
