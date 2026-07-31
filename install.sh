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
#   ./install.sh --bump minor    # major|minor|patch|X.Y.Z, then build
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PREFIX="/Applications"
OPEN_AFTER=1
BUMP=""
BUMPED_TO=""
APP_NAME="ClaudeProjectHub.app"
BUNDLE_ID="com.bgentry.ClaudeProjectHub"
SCHEME="ClaudeProjectHub"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --no-open) OPEN_AFTER=0; shift ;;
    --bump) BUMP="${2:?--bump needs major|minor|patch|X.Y.Z}"; shift 2 ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
PREFIX="${PREFIX/#\~/$HOME}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Validate --bump up front. This used to be checked inside bump_version,
# which runs after the prerequisite checks and after quitting any running
# copy — so a typo'd version quit the user's app and *then* errored.
# Nothing destructive should happen before the arguments are known good.
if [[ -n "$BUMP" && ! "$BUMP" =~ ^(major|minor|patch|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  fail "--bump takes major, minor, patch, or an explicit X.Y.Z (got '$BUMP')"
fi

# Reads/writes the two version settings in project.yml, which are the
# single source of truth — Info.plist interpolates them, so the built app
# always matches. Deliberately does not commit or tag: those are yours to
# make once you've verified the build.
bump_version() {
  local spec="$1" cur curbuild new newbuild major minor patch
  cur="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' project.yml | head -1)"
  curbuild="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' project.yml | head -1)"
  [[ -n "$cur" && -n "$curbuild" ]] \
    || fail "couldn't read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"
  [[ "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "MARKETING_VERSION '$cur' isn't X.Y.Z — bump it by hand this once."

  IFS=. read -r major minor patch <<<"$cur"
  case "$spec" in
    major) new="$((major + 1)).0.0" ;;
    minor) new="${major}.$((minor + 1)).0" ;;
    patch) new="${major}.${minor}.$((patch + 1))" ;;
    *)
      [[ "$spec" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "--bump takes major, minor, patch, or an explicit X.Y.Z (got '$spec')"
      new="$spec"
      ;;
  esac
  newbuild="$((curbuild + 1))"

  # Anchored on the setting name with leading whitespace preserved, so
  # this can't touch the identically-named keys in the info.properties
  # block (those hold $(MARKETING_VERSION) references, not literals).
  sed -i '' "s|^\([[:space:]]*\)MARKETING_VERSION:.*|\1MARKETING_VERSION: \"${new}\"|" project.yml
  sed -i '' "s|^\([[:space:]]*\)CURRENT_PROJECT_VERSION:.*|\1CURRENT_PROJECT_VERSION: \"${newbuild}\"|" project.yml
  echo "  ${cur} (build ${curbuild})  →  ${new} (build ${newbuild})"
  BUMPED_TO="$new"
}

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

# ── Version ──────────────────────────────────────────────────────────
# Before xcodegen, so the regenerated Info.plist picks up the new values.
if [[ -n "$BUMP" ]]; then
  step "Bumping version"
  bump_version "$BUMP"
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

if [[ -n "$BUMPED_TO" ]]; then
  cat <<EOF
$(printf '\033[1mVersion bumped — project.yml is modified but not committed.\033[0m')

Once you've confirmed the build works:

  git add project.yml
  git commit -m "Release v${BUMPED_TO}"
  git tag -a "v${BUMPED_TO}" -m "v${BUMPED_TO}"
  git push && git push --tags

EOF
fi

if [[ "$OPEN_AFTER" == "1" ]]; then
  step "Launching"
  open "$DEST"
fi
