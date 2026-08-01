#!/usr/bin/env bash
#
# Validate relative links between the markdown docs, including #anchors.
# Nothing else checks these: a broken anchor renders as a silent no-op on
# GitHub, and one was introduced (and caught this way) while writing the
# install docs.
#
# Only local links are checked — external URLs would make this flaky and
# dependent on the network.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# GitHub's anchor algorithm, close enough for our headings: lowercase,
# strip anything that isn't alphanumeric/space/hyphen, spaces to hyphens.
anchors_of() {
  grep -E '^#+ ' "$1" \
    | sed 's/^#*[[:space:]]*//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9 -]//g; s/[[:space:]]*$//; s/ /-/g'
}

fails=0
for doc in *.md; do
  # Markdown links whose target is a local .md, optionally with an anchor.
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    file="${target%%#*}"
    anchor=""
    [[ "$target" == *#* ]] && anchor="${target#*#}"

    if [[ ! -f "$file" ]]; then
      printf '  BROKEN  %s -> %s (no such file)\n' "$doc" "$target"
      fails=$((fails + 1)); continue
    fi
    if [[ -n "$anchor" ]] && ! anchors_of "$file" | grep -qx "$anchor"; then
      printf '  BROKEN  %s -> %s (no such heading)\n' "$doc" "$target"
      fails=$((fails + 1)); continue
    fi
    printf '  ok      %s -> %s\n' "$doc" "$target"
  done < <(grep -oE '\]\([A-Za-z0-9_.-]+\.md(#[A-Za-z0-9_-]+)?\)' "$doc" \
             | sed 's/^](//; s/)$//' | sort -u)
done

echo
if (( fails )); then
  echo "$fails broken link(s)" >&2
  exit 1
fi
echo "all internal doc links resolve"
