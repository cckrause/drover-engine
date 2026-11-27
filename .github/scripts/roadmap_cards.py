#!/usr/bin/env python3
"""Draws the README roadmap cards from the repository's issues.

An issue is on the roadmap when it carries one status label
(status:idea, status:todo or status:doing) or the bug label. A bug
needs no status label and must not have one. A closed issue that had
one of them and was closed as completed counts as done.

Writes one count card per status and one list image per status. Each
list shows the issue's title, number, first line of text and, when
the issue has a task list, how many tasks are ticked.

Uses only the Python standard library.
"""

import argparse
import json
import os
import re
import sys
import urllib.request
from html import escape

STATUSES = ("idea", "todo", "doing", "bug", "done")
OPEN_STATUSES = ("idea", "todo", "doing", "bug")

STATUS_TEXT = {
    "idea": "💡 Ideas",
    "todo": "📋 Planned",
    "doing": "🏗 In progress",
    "bug": "🐛 Bugs",
    "done": "✅ Done",
}

# The pill on a single issue card.
CARD_TEXT = {
    "idea": "💡 Idea",
    "todo": "📋 Planned",
    "doing": "🏗 In progress",
    "bug": "🐛 Bug",
    "done": "✅ Done",
}

STATUS_COLOR = {
    "idea": "#8250df",
    "todo": "#0969da",
    "doing": "#bf8700",
    "bug": "#cf222e",
    "done": "#1a7f37",
}

# How many issues one list image shows before it says "+N more".
LIST_LIMIT = {"idea": 8, "todo": 8, "doing": 8, "bug": 8, "done": 5}

CARD_WIDTH = 664
ISSUE_HEIGHT = 100
ISSUE_GAP = 8
STATUS_WIDTH = 140
STATUS_HEIGHT = 96

FONT = ('-apple-system,BlinkMacSystemFont,&quot;Segoe UI&quot;,'
        '&quot;Noto Sans&quot;,Helvetica,Arial,sans-serif')

STYLE = f"""<style>
  text {{ font-family: {FONT}; }}
  .card {{ fill: #ffffff; stroke: #d1d9e0; }}
  .title {{ font-size: 15px; font-weight: 600; fill: #1f2328; }}
  .text {{ font-size: 13px; fill: #59636e; }}
  .small {{ font-size: 12px; fill: #59636e; }}
  .count {{ font-size: 34px; font-weight: 600; fill: #1f2328; }}
  .track {{ fill: #d1d9e0; }}
  @media (prefers-color-scheme: dark) {{
    .card {{ fill: #0d1117; stroke: #3d444d; }}
    .title, .count {{ fill: #f0f6fc; }}
    .text, .small {{ fill: #9198a1; }}
    .track {{ fill: #3d444d; }}
  }}
</style>"""

# Primer octicon "bug-16" (MIT licensed, github.com/primer/octicons).
BUG_ICON = ("M4.72.22a.75.75 0 0 1 1.06 0l1 .999a3.488 3.488 0 0 1 2.441 0l.999-1"
            "a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.775.776c.616.63.995 "
            "1.493.995 2.444v.327c0 .1-.009.197-.025.292.408.14.764.392 1.029.722"
            "l1.968-.787a.75.75 0 0 1 .556 1.392L13 7.258V9h2.25a.75.75 0 0 1 0 1.5"
            "H13v.5c0 .409-.049.806-.141 1.186l2.17.868a.75.75 0 0 1-.557 1.392"
            "l-2.184-.873A4.997 4.997 0 0 1 8 16a4.997 4.997 0 0 1-4.288-2.427"
            "l-2.183.873a.75.75 0 0 1-.558-1.392l2.17-.868A5.036 5.036 0 0 1 3 11"
            "v-.5H.75a.75.75 0 0 1 0-1.5H3V7.258L.971 6.446a.75.75 0 0 1 .558-1.392"
            "l1.967.787c.265-.33.62-.583 1.03-.722a1.677 1.677 0 0 1-.026-.292V4.5"
            "c0-.951.38-1.814.995-2.444L4.72 1.28a.75.75 0 0 1 0-1.06Zm.53 6.28"
            "a.75.75 0 0 0-.75.75V11a3.5 3.5 0 1 0 7 0V7.25a.75.75 0 0 0-.75-.75Z"
            "M6.173 5h3.654A.172.172 0 0 0 10 4.827V4.5a2 2 0 1 0-4 0v.327"
            "c0 .096.077.173.173.173Z")

TASK = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s", re.MULTILINE)
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")


class RoadmapError(Exception):
    pass


def fetch_issues(repo, token):
    issues = []
    page = 1
    while True:
        url = (f"https://api.github.com/repos/{repo}/issues"
               f"?state=all&per_page=100&page={page}")
        request = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "roadmap-cards",
        })
        with urllib.request.urlopen(request) as response:
            batch = json.load(response)
        if not isinstance(batch, list):
            raise RoadmapError(f"unexpected answer from GitHub: {batch!r}")
        issues.extend(item for item in batch if "pull_request" not in item)
        if len(batch) < 100:
            return issues
        page += 1


def status_of(issue):
    """Returns the roadmap status, or None when the issue is not on it."""
    names = [label["name"] for label in issue["labels"]]
    found = [name.split(":", 1)[1] for name in names
             if name.startswith("status:")]
    is_bug = "bug" in names
    if is_bug and found:
        raise RoadmapError(
            f"issue #{issue['number']} is a bug and also has a status label; "
            "bugs take the bug label only")
    if len(found) > 1:
        raise RoadmapError(
            f"issue #{issue['number']} has more than one status label: "
            + ", ".join("status:" + name for name in found))
    if is_bug:
        status = "bug"
    elif found:
        status = found[0]
    else:
        return None
    if status not in OPEN_STATUSES:
        raise RoadmapError(
            f"issue #{issue['number']} has unknown label status:{status}")
    if issue["state"] == "closed":
        if issue.get("state_reason") != "completed":
            return None
        return "done"
    return status


def sort_into_statuses(issues):
    groups = {status: [] for status in STATUSES}
    for issue in issues:
        status = status_of(issue)
        if status is not None:
            groups[status].append(issue)
    for status in OPEN_STATUSES:
        groups[status].sort(key=lambda issue: issue["number"])
    groups["done"].sort(key=lambda issue: issue["closed_at"] or "",
                        reverse=True)
    return groups


def text_width(text, size, bold=False):
    """Rough width in pixels; good enough to decide where to cut."""
    width = 0.0
    for char in text:
        if char in "il.,:;|!'":
            width += 0.28
        elif char in "mwMW":
            width += 0.85
        elif char.isupper() or char.isdigit():
            width += 0.64
        elif ord(char) > 0x2000:
            width += 1.1
        else:
            width += 0.53
    return width * size * (1.06 if bold else 1.0)


def fit(text, size, room, bold=False):
    if text_width(text, size, bold) <= room:
        return text
    while text and text_width(text + "…", size, bold) > room:
        text = text[:-1]
    return text.rstrip() + "…"


def first_line(body):
    """The first line of plain text in the issue, without markdown marks."""
    for line in (body or "").splitlines():
        line = line.strip()
        if not line or line.startswith(("#", "<", "|", "```")):
            continue
        if TASK.match(line):
            continue
        line = LINK.sub(r"\1", line)
        line = line.lstrip("-*> ").replace("**", "").replace("`", "")
        if line:
            return line
    return ""


def tasks(body):
    marks = TASK.findall(body or "")
    return sum(1 for mark in marks if mark in "xX"), len(marks)


def pill(x, y, text, color, size=12):
    width = text_width(text, size, bold=True) + 18
    height = size + 8
    return (f'<rect x="{x - width:.1f}" y="{y}" width="{width:.1f}" '
            f'height="{height}" rx="{height / 2}" fill="{color}" '
            f'fill-opacity="0.15" stroke="{color}" stroke-opacity="0.5"/>'
            f'<text x="{x - width / 2:.1f}" y="{y + height / 2 + size * 0.36:.1f}" '
            f'text-anchor="middle" font-size="{size}" font-weight="600" '
            f'fill="{color}">{escape(text)}</text>')


def issue_icon(issue, status, pad, color):
    if status == "bug" or any(label["name"] == "bug" for label in issue["labels"]):
        return (f'<path transform="translate({pad - 1},16)" fill="{color}" '
                f'd="{BUG_ICON}"/>')
    return (f'<circle cx="{pad + 7}" cy="24" r="6" fill="none" stroke="{color}" '
            f'stroke-width="2"/><circle cx="{pad + 7}" cy="24" r="1.6" '
            f'fill="{color}"/>')


def issue_card(issue, status, top):
    pad = 16
    color = STATUS_COLOR[status]
    number = f"#{issue['number']}"
    label = CARD_TEXT[status]
    label_room = text_width(label, 12, bold=True) + 18 + 12
    title_room = (CARD_WIDTH - 2 * pad - 22 - label_room
                  - text_width(" " + number, 15))
    title = fit(issue["title"], 15, title_room, bold=True)
    line = fit(first_line(issue["body"]), 13, CARD_WIDTH - 2 * pad)

    parts = [
        f'<g transform="translate(0,{top})">',
        f'<rect class="card" x="0.5" y="0.5" width="{CARD_WIDTH - 1}" '
        f'height="{ISSUE_HEIGHT - 1}" rx="6"/>',
        issue_icon(issue, status, pad, color),
        f'<text class="title" x="{pad + 22}" y="29">{escape(title)} '
        f'<tspan class="text" font-weight="400">{number}</tspan></text>',
        pill(CARD_WIDTH - pad, 14, label, color),
    ]
    if line:
        parts.append(f'<text class="text" x="{pad}" y="56">{escape(line)}</text>')

    done, total = tasks(issue["body"])
    if total:
        bar = CARD_WIDTH / 2
        percent = done * 100 // total
        parts.append(f'<rect class="track" x="{pad}" y="70" width="{bar:.1f}" '
                     f'height="8" rx="4"/>')
        if done:
            filled = max(bar * done / total, 8)
            parts.append(f'<rect x="{pad}" y="70" width="{filled:.1f}" '
                         f'height="8" rx="4" fill="{color}"/>')
        parts += [
            f'<text class="small" x="{pad + bar + 12:.1f}" y="78">'
            f'<tspan font-weight="600">{percent}%</tspan> · '
            f'{done} done · {total - done} to do</text>',
        ]
    parts.append("</g>")
    return "".join(parts)


def note_card(text, top, height=48):
    return (f'<g transform="translate(0,{top})">'
            f'<rect class="card" x="0.5" y="0.5" width="{CARD_WIDTH - 1}" '
            f'height="{height - 1}" rx="6"/>'
            f'<text class="text" x="{CARD_WIDTH / 2}" y="{height / 2 + 5}" '
            f'text-anchor="middle">{escape(text)}</text></g>')


def list_svg(status, issues):
    limit = LIST_LIMIT[status]
    shown = issues[:limit]
    parts = []
    top = 0
    for issue in shown:
        parts.append(issue_card(issue, status, top))
        top += ISSUE_HEIGHT + ISSUE_GAP
    if not shown:
        parts.append(note_card("Nothing here right now", top))
        top += 48 + ISSUE_GAP
    elif len(issues) > limit:
        parts.append(note_card(f"+{len(issues) - limit} more", top, 40))
        top += 40 + ISSUE_GAP
    height = top - ISSUE_GAP
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CARD_WIDTH}" '
            f'height="{height}" viewBox="0 0 {CARD_WIDTH} {height}">'
            f'{STYLE}{"".join(parts)}</svg>\n')


def status_svg(status, count):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{STATUS_WIDTH}" '
            f'height="{STATUS_HEIGHT}" viewBox="0 0 {STATUS_WIDTH} {STATUS_HEIGHT}">'
            f'{STYLE}'
            f'<rect class="card" x="0.5" y="0.5" width="{STATUS_WIDTH - 1}" '
            f'height="{STATUS_HEIGHT - 1}" rx="6"/>'
            + pill(STATUS_WIDTH / 2 + (text_width(STATUS_TEXT[status], 12, True) + 18) / 2,
                   14, STATUS_TEXT[status], STATUS_COLOR[status])
            + f'<text class="count" x="{STATUS_WIDTH / 2}" y="80" '
            f'text-anchor="middle">{count}</text></svg>\n')


def write_cards(groups, out):
    os.makedirs(out, exist_ok=True)
    for status in STATUSES:
        with open(os.path.join(out, f"status_{status}.svg"), "w",
                  encoding="utf-8") as file:
            file.write(status_svg(status, len(groups[status])))
        with open(os.path.join(out, f"list_{status}.svg"), "w",
                  encoding="utf-8") as file:
            file.write(list_svg(status, groups[status]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True,
                        help="folder the SVG files are written to")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"),
                        help="owner/name; defaults to GITHUB_REPOSITORY")
    parser.add_argument("--issues-json",
                        help="read issues from this file instead of GitHub")
    args = parser.parse_args()

    try:
        if args.issues_json:
            with open(args.issues_json, encoding="utf-8") as file:
                issues = json.load(file)
        else:
            token = os.environ.get("GITHUB_TOKEN")
            if not args.repo or not token:
                raise RoadmapError("needs --repo (or GITHUB_REPOSITORY) "
                                   "and GITHUB_TOKEN")
            issues = fetch_issues(args.repo, token)
        groups = sort_into_statuses(issues)
        write_cards(groups, args.out)
    except RoadmapError as error:
        print(f"roadmap cards: {error}", file=sys.stderr)
        return 1
    counts = ", ".join(f"{status} {len(groups[status])}" for status in STATUSES)
    print(f"roadmap cards written to {args.out}: {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
