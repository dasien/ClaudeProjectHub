#!/usr/bin/env bash
#
# Compile every bundled launch script the way the hub actually runs it:
# with the hub's placeholders substituted. A syntax error here otherwise
# only surfaces when a user launches a session into that host, as an
# opaque runtime failure.
#
# Substitution matters: a script may legitimately use a placeholder as a
# bare value (e.g. `window id {targetWindowID}`), which is invalid
# AppleScript until substituted — so compiling the raw template would
# report a false failure.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for f in Resources/Scripts/*.applescript; do
  name="$(basename "$f")"
  sed -e 's|{cwd}|/tmp/ci-check|g' \
      -e 's|{claude}|claude|g' \
      -e 's|{marker}|ClaudeProjectHub-CI|g' \
      -e 's|{mode}|newWindow|g' \
      -e 's|{targetWindowID}|0|g' \
      -e 's|{bundleID}|com.example.Host|g' \
      "$f" > "$tmp/$name"
  if osacompile -o "$tmp/out.scpt" "$tmp/$name" 2>"$tmp/err"; then
    printf '  ok      %s\n' "$name"
  else
    printf '  FAILED  %s\n' "$name"
    sed 's/^/            /' "$tmp/err"
    fails=$((fails + 1))
  fi
done

echo
if (( fails )); then
  echo "$fails script(s) failed to compile" >&2
  exit 1
fi
echo "all launch scripts compile"
