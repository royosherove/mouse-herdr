#!/usr/bin/env python3
"""Release only tested main commits with app changes since the last published release."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


BUILD_INPUTS = {"Package.swift", "Package.resolved", "build.sh", "VERSION"}
DOC_SUFFIXES = {".md", ".markdown", ".rst", ".adoc"}


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def app_changed(path):
    if Path(path).suffix.lower() in DOC_SUFFIXES:
        return False
    return path in BUILD_INPUTS or path.startswith(("Sources/", "Resources/"))


def plan_release(head, previous_tag=None):
    if previous_tag:
        base = git("rev-parse", "--verify", "--end-of-options",
                   f"refs/tags/{previous_tag}^{{commit}}")
        subprocess.run(["git", "merge-base", "--is-ancestor", base, head], check=True)
        # --no-renames includes both sides of a move out of the source tree.
        changes = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, head, "--"]
        )
    else:
        changes = subprocess.check_output(
            ["git", "ls-tree", "-r", "--name-only", "-z", head]
        )
    paths = [path for path in changes.decode().split("\0") if path and app_changed(path)]
    if not paths:
        return {"publish": "false", "reason": "No app or build changes since the last release."}

    base_version = git("show", f"{head}:VERSION")
    if not re.fullmatch(r"[0-9]+\.[0-9]+", base_version):
        raise ValueError("VERSION must contain major.minor, such as 1.0.")
    count = git("rev-list", "--count", head)
    return {
        "publish": "true",
        "version": f"{base_version}.{count}",
        "build": count,
        "previous_tag": previous_tag or "",
        "reason": "App changes: " + ", ".join(paths),
    }


def github_api(path, *, missing_ok=False):
    repository = os.environ["GITHUB_REPOSITORY"]
    endpoint = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = Request(
        f"{endpoint}/repos/{repository}/{path}",
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "MouseHerdr-release",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        # An authentication or service failure must never mean "no previous release".
        raise RuntimeError(f"GitHub API failed with HTTP {error.code}: {path}") from None


def publication_state(head, version):
    # REST's release-by-tag endpoint only finds published releases. Query pending
    # tags through GraphQL, in the publishing job where the token has write access.
    owner, name = os.environ["GITHUB_REPOSITORY"].split("/", 1)
    query = """query($owner: String!, $name: String!, $tag: String!) {
      repository(owner: $owner, name: $name) {
        release(tagName: $tag) { isDraft databaseId }
      }
    }"""
    response = subprocess.check_output([
        "gh", "api", "graphql", "-f", f"query={query}",
        "-f", f"owner={owner}", "-f", f"name={name}", "-f", f"tag=v{version}",
    ], text=True)
    release = json.loads(response)["data"]["repository"]["release"]
    if release is None:
        return "new"
    if not release["isDraft"]:
        return "published"
    # target_commitish is exposed by REST, not by GraphQL's Release type.
    draft = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{owner}/{name}/releases/{release['databaseId']}",
    ], text=True))
    if draft["target_commitish"] != head:
        raise ValueError("An existing draft targets a different commit; review it before releasing.")
    return "draft"


def checked_plan(head):
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("RELEASE_SHA must be a full commit SHA.")
    current = github_api("git/ref/heads/main")["object"]["sha"]
    if head != current:
        return {"publish": "false", "reason": "A newer commit is already on main."}

    # Check manual runs too. The most recent CI run for this commit must have passed.
    runs = github_api(
        f"actions/workflows/ci.yml/runs?branch=main&head_sha={head}&per_page=100"
    )["workflow_runs"]
    runs = [run for run in runs if run["head_sha"] == head
            and run["head_branch"] == "main"
            and run["event"] in {"push", "workflow_dispatch"}]
    if not runs or runs[0]["status"] != "completed" or runs[0]["conclusion"] != "success":
        return {"publish": "false", "reason": "The latest CI run for this commit has not passed."}

    latest = github_api("releases/latest", missing_ok=True)
    result = plan_release(head, latest["tag_name"] if latest else None)
    if result["publish"] == "true":
        existing = github_api(f"releases/tags/v{result['version']}", missing_ok=True)
        if existing:
            return {"publish": "false", "reason": "This version is already published."}
    return result


def main():
    if sys.argv[1:] == ["publish-state"]:
        print(publication_state(os.environ["RELEASE_SHA"], os.environ["VERSION"]))
        return
    if sys.argv[1:]:
        raise ValueError("Usage: release_plan.py [publish-state]")
    result = checked_plan(os.environ["RELEASE_SHA"])
    print(result.pop("reason"))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in result.items():
            output.write(f"{key}={value}\n")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
