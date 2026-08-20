"""Check that relative links in tracked Markdown files resolve locally."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(([^)\n]+)\)")
REFERENCE_LINK = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)")
LINE_FRAGMENT = re.compile(r"L([1-9][0-9]*)$")


def tracked_markdown(root: Path) -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z", "--", "*.md"], cwd=root
    )
    return [root / path.decode() for path in output.split(b"\0") if path]


def link_target(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("<") and ">" in raw:
        return raw[1 : raw.index(">")]
    return raw.split(maxsplit=1)[0]


def local_target(raw: str) -> tuple[str, str] | None:
    target = link_target(raw)
    if not target or target.startswith("#") or target.startswith("/"):
        return None
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc:
        return None
    return unquote(parsed.path), unquote(parsed.fragment)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    failures: list[str] = []
    checked = 0
    for markdown in tracked_markdown(root):
        in_fence = False
        for line_number, line in enumerate(markdown.read_text().splitlines(), 1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            raw_targets = [match.group(1) for match in INLINE_LINK.finditer(line)]
            reference = REFERENCE_LINK.match(line)
            if reference:
                raw_targets.append(reference.group(1))
            for raw in raw_targets:
                local = local_target(raw)
                if local is None:
                    continue
                path_text, fragment = local
                target = (markdown.parent / path_text).resolve() if path_text else markdown
                checked += 1
                if not target.exists():
                    failures.append(
                        f"{markdown.relative_to(root)}:{line_number}: missing {path_text}"
                    )
                    continue
                line_fragment = LINE_FRAGMENT.fullmatch(fragment)
                if line_fragment and target.is_file():
                    target_lines = sum(1 for _ in target.open(errors="replace"))
                    expected = int(line_fragment.group(1))
                    if expected > target_lines:
                        failures.append(
                            f"{markdown.relative_to(root)}:{line_number}: "
                            f"{path_text} has {target_lines} lines, not L{expected}"
                        )
    if failures:
        print("markdown-links: failed", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"markdown-links: {checked} relative targets resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
