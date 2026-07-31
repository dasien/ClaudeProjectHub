#!/usr/bin/env bash
#
# Build a Release copy of Claude Project Hub and install it as a normal
# app you can keep in the Dock — no Xcode session required to run it.
#
# Each developer builds and signs with their own Apple team. That's
# deliberate rather than a limitation: macOS ties Accessibility and
# Automation grants to the code signature, so an app you signed yourself
# keeps its permissions across rebuilds. A binary signed by someone else
# would need notarisation (a paid Apple Developer membership) and would
# still prompt for its own grants.
#
# Usage:
#   ./install.sh                 # build + install to /Applications
#   ./install.sh --prefix ~/Applications
#   ./install.sh --no-open       # don't launch afterwards
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PREFIX="/Applications"
OPEN_AFTER=1
APP_NAME="ClaudeProjectHub.app"
BUNDLE_ID="com.bgentry.ClaudeProjectHub"
SCHEME="ClaudeProjectHub"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --no-open) OPEN_AFTER=0; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
PREFIX="${PREFIX/#\~/$HOME}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ── Prerequisites ────────────────────────────────────────────────────
step "Checking prerequisites"

command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode from the App Store."
command -v xcodegen >/dev/null || fail "xcodegen not found. Install it with:  brew install xcodegen"

if [[ ! -f signing.xcconfig ]]; then
  fail "signing.xcconfig is missing. Create it with:
    cp signing.xcconfig.example signing.xcconfig
  then put your Apple Team ID in it. That file explains where to find the
  Team ID — note it is the certificate's OU field, NOT the value in
  parentheses in 'security find-identity' output."
fi

TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' signing.xcconfig | head -1)"
if [[ -z "$TEAM" || "$TEAM" == "YOUR_TEAM_ID" ]]; then
  fail "signing.xcconfig still has a placeholder DEVELOPMENT_TEAM.
  Set it to your real Team ID — see the comments in that file."
fi
echo "  signing team: $TEAM"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q .; then
  fail "No code-signing identities found in your keychain. Sign in to your
  Apple ID in Xcode → Settings → Accounts, then try again."
fi
echo "  code-signing identity: present"

[[ -d "$PREFIX" ]] || fail "install prefix does not exist: $PREFIX"
if [[ ! -w "$PREFIX" ]]; then
  fail "no write permission for $PREFIX.
  Either re-run with sudo, or install to your home folder instead:
    ./install.sh --prefix ~/Applications"
fi

# ── Quit any running copy ────────────────────────────────────────────
# Replacing the bundle underneath a running process leaves it in a
# half-updated state. Claude sessions themselves are unaffected: the hub
# re-attaches to still-live `claude` processes when it next launches.
if pgrep -x "$SCHEME" >/dev/null 2>&1; then
  step "Quitting the running copy"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x "$SCHEME" >/dev/null 2>&1 || break
    sleep 0.25
  done
  pgrep -x "$SCHEME" >/dev/null 2>&1 && fail "couldn't quit the running copy — quit it manually and re-run."
  echo "  quit"
fi

# ── Build ────────────────────────────────────────────────────────────
step "Generating the Xcode project"
xcodegen >/dev/null
echo "  done"

step "Building Release (this takes a minute)"
BUILD_LOG="$(mktemp -t cph-build)"
if ! xcodebuild -project ClaudeProjectHub.xcodeproj \
                -scheme "$SCHEME" \
                -configuration Release \
                build >"$BUILD_LOG" 2>&1; then
  echo
  grep -E 'error:' "$BUILD_LOG" | head -20 >&2 || true
  fail "build failed. Full log: $BUILD_LOG"
fi
rm -f "$BUILD_LOG"
echo "  build succeeded"

PRODUCTS_DIR="$(xcodebuild -project ClaudeProjectHub.xcodeproj \
                           -scheme "$SCHEME" \
                           -configuration Release \
                           -showBuildSettings 2>/dev/null \
                 | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')"
BUILT_APP="$PRODUCTS_DIR/$APP_NAME"
[[ -d "$BUILT_APP" ]] || fail "built app not found at: $BUILT_APP"

# ── Verify the signature before installing ───────────────────────────
step "Verifying signature"
codesign --verify --strict "$BUILT_APP" 2>/dev/null \
  || fail "the built app failed signature verification — refusing to install it."
if ! codesign -d --entitlements - --xml "$BUILT_APP" 2>/dev/null \
     | grep -q 'com.apple.security.automation.apple-events'; then
  fail "the built app is missing the apple-events entitlement, so it could not
  drive Terminal/iTerm2. Check Resources/ClaudeProjectHub.entitlements."
fi
echo "  signature valid, apple-events entitlement present"

# ── Install ──────────────────────────────────────────────────────────
step "Installing to $PREFIX"
DEST="$PREFIX/$APP_NAME"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"
# Copying can leave the bundle's signature looking modified on some
# systems; verify at the destination rather than trusting the source.
codesign --verify --strict "$DEST" 2>/dev/null \
  || fail "signature verification failed after copying to $DEST."
echo "  installed: $DEST"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"

# ── What happens next ────────────────────────────────────────────────
cat <<EOF

$(printf '\033[1mInstalled Claude Project Hub %s (build %s)\033[0m' "$VERSION" "$BUILD_NUM")

  $DEST

To keep it in the Dock: launch it, then right-click its Dock icon →
Options → Keep in Dock.

First launch will ask for permissions, and it needs both:

  • Accessibility  — to focus, move and close host windows.
    System Settings → Privacy & Security → Accessibility.
  • Automation     — asked per host the first time you target it
    (Terminal, iTerm2, …). Approve each prompt.

If you previously ran the app from Xcode, macOS may treat this copy as a
separate app and ask again — that is expected, since the grants are tied
to the bundle's location and signature. If a permission looks stuck after
you granted it, quit and relaunch: TCC often only re-evaluates trust when
the process starts. To start completely clean:

  tccutil reset Accessibility $BUNDLE_ID
  tccutil reset AppleEvents $BUNDLE_ID

Re-run this script any time to update the installed copy. Because you
signed it with your own team ($TEAM), your granted permissions persist
across rebuilds.
EOF

if [[ "$OPEN_AFTER" == "1" ]]; then
  step "Launching"
  open "$DEST"
fi
