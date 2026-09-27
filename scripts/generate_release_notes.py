#!/usr/bin/env python3
"""Generate deterministic release notes from merged GitHub pull requests."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any


def merged_pull_requests(items: list[dict[str, Any]], since: datetime | None) -> list[dict[str, Any]]:
    merged: list[dict[str, Any]] = []
    for item in items:
        merged_at = item.get("merged_at")
        if not merged_at:
            continue
        merged_date = datetime.fromisoformat(merged_at.replace("Z", "+00:00"))
        if since is not None and merged_date <= since:
            continue
        merged.append(item)
    return sorted(merged, key=lambda item: (item["merged_at"], item["number"]))


def render(tag: str, pulls: list[dict[str, Any]], template: str) -> str:
    if pulls:
        changelog = "\n".join(
            f"- {pull['title']} ([#{pull['number']}]({pull['html_url']}))"
            for pull in pulls
        )
    else:
        changelog = "- No merged pull requests since the previous release tag."

    return template.format(tag=tag, changelog=changelog).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pulls", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--since")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    items = json.loads(args.pulls.read_text(encoding="utf-8"))
    if not isinstance(items, list):
        raise SystemExit("pull request input must be a JSON array")
    since = datetime.fromisoformat(args.since.replace("Z", "+00:00")) if args.since else None
    pulls = merged_pull_requests(items, since)
    notes = render(args.tag, pulls, args.template.read_text(encoding="utf-8"))
    args.output.write_text(notes, encoding="utf-8")
    print(f"Generated release notes for {args.tag} from {len(pulls)} merged pull request(s)")


if __name__ == "__main__":
    main()
