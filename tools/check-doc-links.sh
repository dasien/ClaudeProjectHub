#!/usr/bin/env bash
#
# Validate relative links between the markdown docs, including #anchors.
# Nothing else catches these: a broken anchor is a silent no-op on GitHub.
# Covers cross-file and same-file (`](#foo)`) links; external URLs and
# non-.md targets are deliberately out of scope.
#
# The slug rules below match github-slugger and were verified against the
# anchors GitHub emitted for all 98 headings in these docs. Three are easy
# to get wrong: underscores survive, punctuation is stripped before spaces
# become hyphens with no trim after (so `Settings (⌘,)` -> `settings-`),
# and lines inside ``` fences aren't headings. Setext headings aren't
# recognised; no doc uses them.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Standard library only, no f-strings, so any python3 works.
command -v python3 >/dev/null || {
  echo "check-doc-links: python3 is required but not on PATH" >&2
  exit 1
}

exec python3 - <<'PY'
import glob
import os
import re
import sys

HEADING = re.compile(r'^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$')
# Inline markdown link targets: the ( ... ) half of [text](target).
LINK = re.compile(r'\]\(\s*([^)\s]+?)\s*\)')
# Stripped before finding links (`](#foo)` in backticks is prose about a
# link), but NOT before slugging a heading, where GitHub does slug the
# backticked text.
CODE_SPAN = re.compile(r'(`+)[\s\S]*?\1')
# Anything with a URL scheme, or a protocol-relative URL, is external.
EXTERNAL = re.compile(r'^(?:[a-z][a-z0-9+.-]*:|//)', re.IGNORECASE)


def content_lines(text):
    """Lines outside fenced code blocks. A ``` or ~~~ fence runs until a
    line starting with the same marker."""
    fence = None
    for line in text.splitlines():
        stripped = line.strip()
        if fence is not None:
            if stripped.startswith(fence):
                fence = None
            continue
        if stripped.startswith('```') or stripped.startswith('~~~'):
            fence = stripped[:3]
            continue
        yield line


def slug(text):
    """Lowercase, drop everything that isn't a word character / space /
    hyphen, then spaces to hyphens. Order matters; no trailing trim."""
    return re.sub(r'[^\w \-]', '', text.lower(), flags=re.UNICODE).replace(' ', '-')


def anchors_of(path):
    with open(path, encoding='utf-8') as handle:
        text = handle.read()
    seen, anchors = {}, set()
    for line in content_lines(text):
        match = HEADING.match(line)
        if not match:
            continue
        base = slug(match.group(2))
        # GitHub disambiguates repeated headings as foo, foo-1, foo-2 ...
        if base in seen:
            seen[base] += 1
            anchors.add('%s-%d' % (base, seen[base]))
        else:
            seen[base] = 0
            anchors.add(base)
    return anchors


anchor_cache = {}


def anchors_cached(path):
    if path not in anchor_cache:
        anchor_cache[path] = anchors_of(path)
    return anchor_cache[path]


fails = 0
for doc in sorted(glob.glob('*.md')):
    with open(doc, encoding='utf-8') as handle:
        text = handle.read()
    targets = sorted({
        target
        for line in content_lines(text)
        for target in LINK.findall(CODE_SPAN.sub('', line))
    })
    for target in targets:
        if EXTERNAL.match(target):
            continue
        file_part, _, anchor = target.partition('#')
        # A bare "#anchor" points at the current document.
        if file_part == '':
            path = doc
        elif file_part.endswith('.md'):
            path = file_part
        else:
            continue  # not a markdown target; same scope as before

        if not os.path.isfile(path):
            print('  BROKEN  %s -> %s (no such file)' % (doc, target))
            fails += 1
            continue
        if anchor and anchor not in anchors_cached(path):
            print('  BROKEN  %s -> %s (no such heading)' % (doc, target))
            fails += 1
            continue
        print('  ok      %s -> %s' % (doc, target))

print()
if fails:
    print('%d broken link(s)' % fails, file=sys.stderr)
    sys.exit(1)
print('all internal doc links resolve')
PY
