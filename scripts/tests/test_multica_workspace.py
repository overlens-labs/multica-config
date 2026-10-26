"""Bootstrap tests against an in-memory fake of the multica CLI.

Run: python3 -m unittest discover -s scripts/tests
"""

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "multica-workspace.py"
spec = importlib.util.spec_from_file_location("multica_workspace", SCRIPT)
mw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mw)


class FakeMultica:
    """Implements just the commands bootstrap() uses for autopilots."""

    def __init__(self):
        self.autopilots = {}  # id -> {"title", "triggers": [..]}
        self.calls = []
        self._next = 0

    def _id(self, prefix):
        self._next += 1
        return f"{prefix}-{self._next}"

    def __call__(self, *args, parse=True, dry_run=False):
        self.calls.append(args)
        if dry_run:
            return None
        group, cmd, *rest = args
        if (group, cmd) in {("skill", "list"), ("agent", "list"), ("runtime", "list")}:
            return []
        if group != "autopilot":
            raise AssertionError(f"unexpected command {args}")
        if cmd == "list":
            return {"autopilots": [{"id": i, "title": a["title"]} for i, a in self.autopilots.items()]}
        if cmd == "create":
            pid = self._id("ap")
            self.autopilots[pid] = {"title": rest[rest.index("--title") + 1], "triggers": []}
            return {"id": pid}
        if cmd == "update":
            return {}
        pid = rest[0]
        triggers = self.autopilots[pid]["triggers"]
        if cmd == "trigger-list":
            return {"triggers": [dict(t) for t in triggers]}
        if cmd == "trigger-add":
            opt = dict(zip(rest[1::2], rest[2::2]))
            triggers.append({"id": self._id("tr"), "kind": opt["--kind"], "cron_expression": opt["--cron"],
                             "timezone": opt["--timezone"], "label": opt["--label"]})
            return triggers[-1]
        if cmd == "trigger-update":
            t = next(t for t in triggers if t["id"] == rest[1])
            t["label"] = rest[rest.index("--label") + 1]
            return t
        if cmd == "trigger-delete":
            self.autopilots[pid]["triggers"] = [t for t in triggers if t["id"] != rest[1]]
            return {}
        raise AssertionError(f"unexpected command {args}")


def write_template(root: Path, triggers):
    d = root / "autopilots"
    d.mkdir(parents=True, exist_ok=True)
    (d / "digest.json").write_text(json.dumps({
        "title": "Digest", "agent": "Mika", "mode": "create_issue", "description": "prompt",
        "issue_title_template": "Digest {{date}}", "status": "active", "triggers": triggers,
    }), encoding="utf-8")


class BootstrapSchedulesTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeMultica()
        self.orig = mw.multica
        mw.multica = self.fake
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        mw.multica = self.orig
        self.tmp.cleanup()

    def run_bootstrap(self, dry=False):
        with redirect_stdout(io.StringIO()):
            mw.bootstrap(self.root, {}, dry)

    def schedules(self):
        (ap,) = self.fake.autopilots.values()
        return sorted((t["cron_expression"], t["timezone"], t["label"]) for t in ap["triggers"])

    def test_cron_change_replaces_schedule_and_is_idempotent(self):
        write_template(self.root, [{"cron": "0 11 * * 2-5", "timezone": "America/Sao_Paulo", "label": "11h"}])
        self.run_bootstrap()
        self.assertEqual(self.schedules(), [("0 11 * * 2-5", "America/Sao_Paulo", "11h")])

        write_template(self.root, [{"cron": "0 9 * * 1-5", "timezone": "America/Sao_Paulo", "label": "9h"}])
        self.run_bootstrap()
        self.run_bootstrap()
        self.assertEqual(self.schedules(), [("0 9 * * 1-5", "America/Sao_Paulo", "9h")])

        before = len(self.fake.calls)
        self.run_bootstrap()
        writes = [c for c in self.fake.calls[before:] if c[1] in {"trigger-add", "trigger-update", "trigger-delete"}]
        self.assertEqual(writes, [], "a converged workspace must not get trigger writes")

    def test_label_change_updates_in_place_and_duplicates_are_removed(self):
        write_template(self.root, [{"cron": "0 11 * * *", "timezone": "UTC", "label": "a"}])
        self.run_bootstrap()
        (ap,) = self.fake.autopilots.values()
        ap["triggers"].append({"id": "dup", "kind": "schedule", "cron_expression": "0 11 * * *", "timezone": "UTC", "label": "a"})
        ap["triggers"].append({"id": "hook", "kind": "webhook", "cron_expression": None, "timezone": None, "label": "hook"})

        write_template(self.root, [{"cron": "0 11 * * *", "timezone": "UTC", "label": "b"}])
        self.run_bootstrap()
        kinds = sorted((t["kind"], t["label"]) for t in ap["triggers"])
        self.assertEqual(kinds, [("schedule", "b"), ("webhook", "hook")])

    def test_dry_run_changes_nothing(self):
        write_template(self.root, [{"cron": "0 11 * * *", "timezone": "UTC", "label": "a"}])
        self.run_bootstrap()
        write_template(self.root, [{"cron": "0 12 * * *", "timezone": "UTC", "label": "a"}])
        self.run_bootstrap(dry=True)
        self.assertEqual(self.schedules(), [("0 11 * * *", "UTC", "a")])


if __name__ == "__main__":
    unittest.main()
