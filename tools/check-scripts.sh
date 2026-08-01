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
# Coverage caveat, and why the SKIP path exists: `osacompile` resolves
# app-specific terminology out of the target app's scripting dictionary,
# which means the app has to be installed. `create window with default
# profile` compiles against iTerm2's dictionary and is a syntax error
# without it (-2741, "found class name"). Scripts that only use generic
# terminology — every JetBrains one, which drives the IDE through System
# Events keystrokes — compile fine with the app absent. So a failure is
# only meaningful when every app the script tells is installed; when one
# isn't, this reports SKIP rather than pretending either result.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Colon-separated app names whose dictionary is known-unavailable in this
# environment, treated as absent even if the bundle is on disk. Set by CI
# after probing, because the two are not the same thing: a cask-installed
# iTerm.app sat in /Applications while osacompile still could not resolve
# `create window with default profile`, so a disk check alone reported a
# failure nobody could act on.
NO_DICT="${CPH_SCRIPT_CHECK_NO_DICT:-}"

# Deliberately a filesystem lookup rather than `path to application`:
# that hung for over two minutes on one installed app while probing
# Launch Services, which is not acceptable in a check script.
app_installed() {
  local name="$1" dir
  case ":$NO_DICT:" in *":$name:"*) return 1 ;; esac
  for dir in /Applications /Applications/Utilities "$HOME/Applications" \
             /System/Applications /System/Applications/Utilities; do
    [[ -d "$dir/$name.app" ]] && return 0
  done
  return 1
}

# Apps a script can tell without needing anything installed.
always_present() {
  case "$1" in
    "System Events"|"Finder"|"System Preferences"|"System Settings") return 0 ;;
    *) return 1 ;;
  esac
}

# Names of tell'd apps that aren't installed, one per line.
missing_apps() {
  local app
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    always_present "$app" && continue
    app_installed "$app" || echo "$app"
  done < <(grep -oE 'tell application "[^"]+"' "$1" \
           | sed -E 's/^tell application "(.*)"$/\1/' | sort -u)
}

fails=0
skips=0
oks=0
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
    oks=$((oks + 1))
    continue
  fi

  absent="$(missing_apps "$tmp/$name" | paste -sd', ' -)"
  if [[ -n "$absent" ]]; then
    printf '  SKIP    %s (not installed: %s)\n' "$name" "$absent"
    skips=$((skips + 1))
  else
    printf '  FAILED  %s\n' "$name"
    sed 's/^/            /' "$tmp/err"
    fails=$((fails + 1))
  fi
done

echo
printf '%d compiled, %d skipped, %d failed\n' "$oks" "$skips" "$fails"
if (( fails )); then
  echo "launch script compilation failed" >&2
  exit 1
fi
if (( skips )); then
  echo "note: skipped scripts were not verified — run this on a machine with those hosts installed."
fi
