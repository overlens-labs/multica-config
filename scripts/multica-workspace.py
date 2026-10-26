#!/usr/bin/env python3
"""Export a Multica workspace's agents, skills and autopilots to files, and
recreate them in another workspace (OVER-9 bootstrap).

    multica-workspace.py export    <dir>    # current workspace -> files
    multica-workspace.py bootstrap <dir>    # files -> current workspace

Layout of <dir>:
    skills/<name>/skill.json      name, description, config
    skills/<name>/SKILL.md        skill body
    skills/<name>/files/...       extra skill files
    agents/<slug>.json            settings (runtime by provider, skills by name)
    agents/<slug>.md              instructions
    autopilots/<slug>.json        prompt, assignee by name, schedule triggers

Matching is by name (skills, agents) and title (autopilots), so bootstrap is
idempotent: it creates what's missing and updates what exists. The only
deletions are schedule triggers that are no longer in an autopilot's template
(the template owns its schedules). It never touches agent env or MCP config:
credentials are set by sync-multica.sh from the OpenTofu outputs.

Workspace-specific IDs (members, projects, runtimes) are not exported, nor
are built-in agents such as Mika (every workspace has them).
Run `multica workspace switch <id>` (or pass --profile via MULTICA_* env) to
choose the target workspace before bootstrapping.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

AGENT_FIELDS = ("description", "max_concurrent_tasks", "model", "thinking_level", "custom_args", "runtime_config")


def multica(*args: str, parse: bool = True, dry_run: bool = False):
    cmd = ["multica", *args]
    if dry_run:
        print("  (dry-run) " + " ".join(_redact(cmd)))
        return None
    out = subprocess.run(cmd + (["--output", "json"] if parse else []), check=True, capture_output=True, text=True)
    return json.loads(out.stdout) if parse and out.stdout.strip() else out.stdout


def _redact(cmd: list[str]) -> list[str]:
    # Long bodies (instructions, prompts) make dry-run output unreadable.
    return [a if len(a) < 120 else a[:60].replace("\n", " ") + "…" for a in cmd]


def slugify(name: str) -> str:
    ascii_name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def as_list(data, key: str):
    return data.get(key, []) if isinstance(data, dict) else data


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

def export(root: Path) -> None:
    runtimes = {r["id"]: r.get("provider", "") for r in multica("runtime", "list")}
    agents = [a for a in multica("agent", "list") if not a.get("archived_at")]
    agent_names = {a["id"]: a["name"] for a in agents}

    for s in multica("skill", "list"):
        full = multica("skill", "get", s["id"], "--with-content")
        d = root / "skills" / full["name"]
        write_json(d / "skill.json", {"name": full["name"], "description": full.get("description", ""), "config": full.get("config") or {}})
        (d / "SKILL.md").write_text(full.get("content", ""), encoding="utf-8")
        for f in full.get("files") or []:
            target = d / "files" / f["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f.get("content", ""), encoding="utf-8")
        print(f"skill    {full['name']}")

    for a in agents:
        if a.get("system_key"):
            # Built-in agents (e.g. Mika) exist in every workspace; autopilots
            # still reference them by name.
            print(f"skip     agent {a['name']}: built-in ({a['system_key']})")
            continue
        slug = slugify(a["name"])
        settings = {"name": a["name"], "runtime_provider": runtimes.get(a.get("runtime_id"), "")}
        settings.update({k: a.get(k) for k in AGENT_FIELDS})
        settings["permission_mode"] = a.get("permission_mode") or "private"
        settings["public_to_workspace"] = any(t.get("target_type") == "workspace" for t in a.get("invocation_targets") or [])
        settings["skills"] = sorted(s["name"] for s in a.get("skills") or [])
        write_json(root / "agents" / f"{slug}.json", settings)
        (root / "agents" / f"{slug}.md").write_text(a.get("instructions") or "", encoding="utf-8")
        print(f"agent    {a['name']}")

    for ap in as_list(multica("autopilot", "list"), "autopilots"):
        full = multica("autopilot", "get", ap["id"])
        p = full["autopilot"]
        if p.get("assignee_type") != "agent" or p.get("assignee_id") not in agent_names:
            print(f"skip     autopilot {p['title']}: assignee is not an active agent", file=sys.stderr)
            continue
        write_json(root / "autopilots" / f"{slugify(p['title'])}.json", {
            "title": p["title"],
            "agent": agent_names[p["assignee_id"]],
            "mode": p["execution_mode"],
            "issue_title_template": p.get("issue_title_template") or "",
            "status": p.get("status", "active"),
            "description": p.get("description") or "",
            "triggers": [
                {"cron": t["cron_expression"], "timezone": t.get("timezone") or "UTC", "label": t.get("label") or ""}
                for t in full.get("triggers") or [] if t.get("kind") == "schedule"
            ],
        })
        print(f"autopilot {p['title']}")


# ---------------------------------------------------------------------------
# bootstrap
# ---------------------------------------------------------------------------

def pick_runtime(provider: str, overrides: dict[str, str], runtimes: list[dict]) -> str:
    if provider in overrides:
        return overrides[provider]
    matches = [r["id"] for r in runtimes if r.get("provider") == provider]
    if not matches:
        sys.exit(f"No runtime with provider '{provider}' in this workspace; pass --runtime {provider}=<runtime-id>.")
    return matches[0]


def bootstrap(root: Path, overrides: dict[str, str], dry: bool) -> None:
    skills = {s["name"]: s["id"] for s in multica("skill", "list")}
    for meta_file in sorted((root / "skills").glob("*/skill.json")):
        d = meta_file.parent
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
        body = str(d / "SKILL.md")
        common = ["--description", meta.get("description", ""), "--config", json.dumps(meta.get("config") or {}), "--content-file", body]
        if meta["name"] in skills:
            sid = skills[meta["name"]]
            print(f"skill    {meta['name']}: update")
            multica("skill", "update", sid, *common, dry_run=dry)
        else:
            print(f"skill    {meta['name']}: create")
            created = multica("skill", "create", "--name", meta["name"], *common, dry_run=dry)
            sid = created["id"] if created else f"<{meta['name']}>"
            skills[meta["name"]] = sid
        for f in sorted(p for p in (d / "files").rglob("*") if p.is_file()) if (d / "files").exists() else []:
            multica("skill", "files", "upsert", sid, "--path", str(f.relative_to(d / "files")), "--content-file", str(f), dry_run=dry)

    runtimes = multica("runtime", "list")
    agents = {a["name"]: a for a in multica("agent", "list") if not a.get("archived_at")}
    for meta_file in sorted((root / "agents").glob("*.json")):
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
        instructions = meta_file.with_suffix(".md").read_text(encoding="utf-8")
        flags = ["--instructions", instructions, "--description", meta.get("description") or "",
                 "--max-concurrent-tasks", str(meta.get("max_concurrent_tasks") or 1),
                 "--model", meta.get("model") or "", "--thinking-level", meta.get("thinking_level") or "",
                 "--custom-args", json.dumps(meta.get("custom_args") or []),
                 "--runtime-config", json.dumps(meta.get("runtime_config") or {}),
                 "--permission-mode", meta.get("permission_mode") or "private"]
        if meta.get("permission_mode") == "public_to" and meta.get("public_to_workspace"):
            flags.append("--public-to-workspace")
        if meta["name"] in agents:
            aid = agents[meta["name"]]["id"]
            print(f"agent    {meta['name']}: update")
            multica("agent", "update", aid, *flags, dry_run=dry)
        else:
            rid = pick_runtime(meta.get("runtime_provider", ""), overrides, runtimes)
            print(f"agent    {meta['name']}: create on runtime {rid}")
            created = multica("agent", "create", "--name", meta["name"], "--runtime-id", rid, *flags, dry_run=dry)
            aid = created["id"] if created else f"<{meta['name']}>"
        wanted = [skills[s] for s in meta.get("skills") or [] if s in skills]
        missing = [s for s in meta.get("skills") or [] if s not in skills]
        if missing:
            print(f"  skills not found: {', '.join(missing)}", file=sys.stderr)
        if wanted:
            multica("agent", "skills", "add", aid, "--skill-ids", ",".join(wanted), dry_run=dry)

    autopilots = {p["title"]: p for p in as_list(multica("autopilot", "list"), "autopilots")}
    for f in sorted((root / "autopilots").glob("*.json")):
        meta = json.loads(f.read_text(encoding="utf-8"))
        flags = ["--agent", meta["agent"], "--mode", meta["mode"], "--description", meta["description"]]
        if meta.get("issue_title_template"):
            flags += ["--issue-title-template", meta["issue_title_template"]]
        if meta["title"] in autopilots:
            pid = autopilots[meta["title"]]["id"]
            print(f"autopilot {meta['title']}: update")
            multica("autopilot", "update", pid, *flags, "--status", meta.get("status", "active"), dry_run=dry)
            current = [t for t in as_list(multica("autopilot", "trigger-list", pid), "triggers") if t.get("kind") == "schedule"]
        else:
            print(f"autopilot {meta['title']}: create")
            created = multica("autopilot", "create", "--title", meta["title"], *flags, dry_run=dry)
            pid = (created.get("autopilot", created)["id"]) if created else f"<{meta['title']}>"
            current = []
        reconcile_schedules(pid, meta.get("triggers") or [], current, dry)


def reconcile_schedules(pid: str, wanted: list[dict], current: list[dict], dry: bool) -> None:
    """Make the autopilot's schedule triggers equal the template's.

    The template owns every schedule trigger: one whose (cron, timezone) is no
    longer in the template is deleted, so changing a cron replaces the old
    schedule instead of adding a second one. Webhook triggers are not touched.
    """
    by_key: dict[tuple[str, str], list[dict]] = {}
    for t in current:
        by_key.setdefault((t["cron_expression"], t.get("timezone") or "UTC"), []).append(t)
    for t in wanted:
        key = (t["cron"], t.get("timezone") or "UTC")
        label = t.get("label", "")
        matches = by_key.pop(key, [])
        if not matches:
            multica("autopilot", "trigger-add", pid, "--kind", "schedule", "--cron", key[0],
                    "--timezone", key[1], "--label", label, dry_run=dry)
            continue
        keep, extra = matches[0], matches[1:]
        if (keep.get("label") or "") != label:
            multica("autopilot", "trigger-update", pid, keep["id"], "--label", label, dry_run=dry)
        by_key.setdefault(("__duplicates__", ""), []).extend(extra)
    for stale in (t for ts in by_key.values() for t in ts):
        print(f"  removing schedule {stale['cron_expression']} ({stale.get('timezone') or 'UTC'})")
        multica("autopilot", "trigger-delete", pid, stale["id"], dry_run=dry)

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("export", help="dump the current workspace to <dir>")
    ex.add_argument("dir", type=Path)
    bs = sub.add_parser("bootstrap", help="create/update the current workspace from <dir>")
    bs.add_argument("dir", type=Path)
    bs.add_argument("--runtime", action="append", default=[], metavar="PROVIDER=RUNTIME_ID",
                    help="runtime for new agents of a provider (default: first runtime of that provider)")
    bs.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    try:
        if args.cmd == "export":
            export(args.dir)
        else:
            overrides = dict(r.split("=", 1) for r in args.runtime)
            bootstrap(args.dir, overrides, args.dry_run)
    except subprocess.CalledProcessError as e:
        sys.exit(f"multica {' '.join(_redact(e.cmd[1:]))} failed:\n{e.stderr}")


if __name__ == "__main__":
    main()
