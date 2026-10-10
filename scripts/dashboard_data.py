#!/usr/bin/env python3
"""Collects release, environment and pipeline data for the dashboard into dashboard/data.json.

Runs in the Pages workflow (and locally) using the `gh` CLI, so the published page is static:
visitors never hit GitHub API rate limits.

    GITHUB_REPOSITORY=owner/repo python3 scripts/dashboard_data.py
"""
import datetime as dt
import glob
import json
import os
import re
import subprocess

REPO = os.environ.get("GITHUB_REPOSITORY", "deep200315/Shelfy")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def api(path):
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 else None


def parse_time(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def asset(a):
    return {"name": a["name"], "url": a["browser_download_url"], "size": a["size"], "downloads": a["download_count"]}


def release(r):
    return {
        "tag": r["tag_name"],
        "name": r["name"] or r["tag_name"],
        "prerelease": r["prerelease"],
        "pulledBack": r["prerelease"] and r["tag_name"] != "dev",
        "published": r["published_at"],
        "commit": r["target_commitish"][:7],
        "url": r["html_url"],
        "assets": [asset(a) for a in r["assets"]],
        "downloads": sum(a["download_count"] for a in r["assets"]),
    }


def run(r):
    start, end = parse_time(r["run_started_at"]), parse_time(r["updated_at"])
    return {
        "workflow": r["name"],
        "branch": r["head_branch"],
        "event": r["event"],
        "status": r["status"],
        "conclusion": r["conclusion"],
        "started": r["run_started_at"],
        "seconds": int((end - start).total_seconds()) if start and end and r["status"] == "completed" else None,
        "commit": r["head_sha"][:7],
        "title": r["display_title"],
        "url": r["html_url"],
    }


def unreleased_changes():
    try:
        text = open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8").read()
    except OSError:
        return []
    match = re.search(r"^## \[Unreleased\]\s*$(.*?)(?=^## \[)", text, re.M | re.S)
    if not match:
        return []
    changes, group = [], None
    for line in match.group(1).splitlines():
        if line.startswith("### "):
            group = line[4:].strip()
        elif line.startswith("- "):
            changes.append({"group": group or "Changed", "text": line[2:].strip()})
    return changes


def main():
    repo = api(f"repos/{REPO}") or {}
    releases = [release(r) for r in (api(f"repos/{REPO}/releases?per_page=30") or [])]
    runs = [run(r) for r in (api(f"repos/{REPO}/actions/runs?per_page=50") or {}).get("workflow_runs", [])]
    compare = api(f"repos/{REPO}/compare/main...develop") or {}
    pulls = api(f"repos/{REPO}/pulls?state=open&per_page=30") or []

    production = next((r for r in releases if not r["prerelease"]), None)
    development = next((r for r in releases if r["tag"] == "dev"), None)
    tests = sum(len(re.findall(r"@Test\b", open(f, encoding="utf-8").read()))
                for f in glob.glob(os.path.join(ROOT, "Tests", "**", "*.swift"), recursive=True))

    data = {
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "repo": {
            "name": repo.get("full_name", REPO),
            "url": repo.get("html_url", f"https://github.com/{REPO}"),
            "description": repo.get("description"),
            "stars": repo.get("stargazers_count", 0),
            "license": (repo.get("license") or {}).get("spdx_id"),
        },
        "environments": {"production": production, "development": development},
        "promotion": {
            "aheadBy": compare.get("ahead_by", 0),
            "commits": [
                {"sha": c["sha"][:7], "title": c["commit"]["message"].splitlines()[0], "url": c["html_url"]}
                for c in reversed(compare.get("commits", [])[-12:])
            ],
            "startReleaseUrl": f"https://github.com/{REPO}/actions/workflows/release.yml",
        },
        "releases": releases,
        "runs": runs,
        "pulls": [{"number": p["number"], "title": p["title"], "url": p["html_url"],
                   "base": p["base"]["ref"], "head": p["head"]["ref"]} for p in pulls],
        "unreleased": unreleased_changes(),
        "tests": tests,
    }
    path = os.path.join(ROOT, "dashboard", "data.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1)
    print(f"Wrote {path}: {len(releases)} releases, {len(runs)} runs, {tests} tests, develop +{data['promotion']['aheadBy']}")


if __name__ == "__main__":
    main()
