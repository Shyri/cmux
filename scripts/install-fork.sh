#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Chatmux"
BUNDLE_ID="com.cmuxterm.app.fork"
BASE_APP_NAME="cmux"

usage() {
  cat <<EOF
Usage: ./scripts/install-fork.sh [--launch] [--dest <path>] [--name <name>] [--bundle-id <id>]

Builds cmux in Release configuration and installs a renamed copy to the
destination directory (default: /Applications) as "${APP_NAME}.app", with
an isolated bundle identifier so it runs side-by-side with the official
cmux app. Replaces any existing "${APP_NAME}.app" at that destination.

Options:
  --launch            Open the installed app after copying.
  --dest <path>       Override the install directory (default: /Applications).
  --name <name>       Override the app display name (default: ${APP_NAME}).
  --bundle-id <id>    Override the bundle identifier (default: ${BUNDLE_ID}).
  -h, --help          Show this help.

Environment:
  CMUX_SKIP_ZIG_BUILD=1   Skip the Ghostty/zig build step (forwarded to xcodebuild).
EOF
}

LAUNCH=0
DEST_DIR="/Applications"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch)
      LAUNCH=1
      shift
      ;;
    --dest)
      DEST_DIR="${2:-}"
      if [[ -z "$DEST_DIR" ]]; then
        echo "error: --dest requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
  # Skip all signing during the build. The Release configuration
  # references entitlements that require a Development/Distribution
  # certificate (Automatic signing + empty DEVELOPMENT_TEAM rejects
  # the build). The fork is meant for local install only; we re-sign
  # ad-hoc after the build with the simpler root-level entitlements.
  CODE_SIGN_IDENTITY=-
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGN_ENTITLEMENTS=
)
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(CMUX_SKIP_ZIG_BUILD=1)
fi
XCODEBUILD_ARGS+=(build)

echo "==> Building cmux (Release)..."
xcodebuild "${XCODEBUILD_ARGS[@]}"

SRC_APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${BASE_APP_NAME}.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"

if [[ -z "${SRC_APP_PATH}" || ! -d "${SRC_APP_PATH}" ]]; then
  echo "error: ${BASE_APP_NAME}.app not found in DerivedData after build" >&2
  exit 1
fi

DEST="${DEST_DIR%/}/${APP_NAME}.app"

echo "==> Installing:"
echo "    from:       $SRC_APP_PATH"
echo "    to:         $DEST"
echo "    bundle id:  $BUNDLE_ID"

# Quit any running fork at the destination before replacing.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
pkill -f "${DEST}/Contents/MacOS/${BASE_APP_NAME}" || true
sleep 0.3

SUDO=""
if [[ ! -w "$DEST_DIR" ]]; then
  SUDO="sudo"
  echo "==> ${DEST_DIR} is not writable; using sudo"
fi

if [[ -e "$DEST" ]]; then
  echo "==> Removing existing ${DEST}"
  $SUDO /bin/rm -rf "$DEST"
fi

# ditto preserves extended attributes, symlinks, and permissions better than cp for app bundles.
$SUDO /usr/bin/ditto "$SRC_APP_PATH" "$DEST"

# Patch Info.plist to give the fork a distinct identity so it runs side-by-side
# with the official cmux app.
INFO_PLIST="$DEST/Contents/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  $SUDO /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "$INFO_PLIST"
  $SUDO /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$INFO_PLIST"
  $SUDO /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$INFO_PLIST"
fi

# Re-sign ad-hoc so Gatekeeper/codesign accepts the patched bundle.
# `-i ${BUNDLE_ID}` is critical: by default `codesign --sign -` derives
# the signature Identifier from the executable name (`cmux`), which
# collides with the official cmux's Identifier. macOS's TCC database
# keys permission grants by that Identifier, not by CFBundleIdentifier,
# so without `-i` the fork either inherits TCC state from the official
# app or — more commonly — gets re-prompted on every launch because the
# signature identity is unstable / ambiguous. Pinning the Identifier to
# the fork's bundle id is what makes "Documents access" /
# "App Management" permissions persist across launches.
#
# Apply the simple root-level entitlements (JIT, mic, camera, apple
# events, library validation off) — we deliberately skip the team-
# scoped `Resources/cmux.entitlements` (`keychain-access-groups` needs
# a real `AppIdentifierPrefix`) since ad-hoc signing has no team.
FORK_ENTITLEMENTS="$REPO_ROOT/cmux.entitlements"
CODESIGN_ARGS=(
  --force
  --sign -
  -i "${BUNDLE_ID}"
  --timestamp=none
  --generate-entitlement-der
)
if [[ -f "$FORK_ENTITLEMENTS" ]]; then
  CODESIGN_ARGS+=(--entitlements "$FORK_ENTITLEMENTS")
fi
# Re-sign nested helpers (Sparkle XPC, plugins, frameworks, dock tile
# plugin) before the outer bundle. Without this, the outer signature
# can fail validation because the inner components still carry the old
# codesign identifier. Errors are surfaced (no silent fallback) — a
# failure here propagates and breaks the outer signature, which breaks
# TCC persistence.
#
# IMPORTANT: This must cover `.plugin` (CmuxDockTilePlugin lives here),
# `.appex`, `.xpc`, `.framework` and `.app`. The dock tile plugin is
# loaded by `com.apple.dock.extra` and KEEPS RUNNING after you quit the
# app — if it has a stale signature, it triggers TCC prompts that no
# amount of "Allow" clicks will silence, because TCC cannot persist a
# grant against the colliding Identifier.
NESTED_DEPTH_FIRST=()
while IFS= read -r -d '' nested; do
  [[ "$nested" == "$DEST" ]] && continue
  NESTED_DEPTH_FIRST+=("$nested")
done < <(/usr/bin/find "$DEST" \
  \( -name "*.app" -o -name "*.appex" -o -name "*.xpc" \
     -o -name "*.framework" -o -name "*.plugin" -o -name "*.bundle" \) \
  -print0)
# Sign deepest paths first so containers are signed only after their
# embedded children.
IFS=$'\n' NESTED_SORTED=($(printf '%s\n' "${NESTED_DEPTH_FIRST[@]}" \
  | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)) || true
unset IFS
for nested in "${NESTED_SORTED[@]}"; do
  echo "==> Re-signing nested bundle: ${nested#$DEST/}"
  $SUDO /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der \
    "$nested"
done

echo "==> Re-signing outer bundle as ${BUNDLE_ID}"
$SUDO /usr/bin/codesign "${CODESIGN_ARGS[@]}" "$DEST"

# Verify the signature actually took the fork identifier — fail hard if
# it didn't. Silently leaving Identifier=cmux is what historically made
# TCC re-prompt for Documents/App Management permission on every launch
# (TCC keys grants by the codesign Identifier, not by CFBundleIdentifier,
# and Identifier=cmux collides with the official app).
SIG_ID="$($SUDO /usr/bin/codesign -dvv "$DEST" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$SIG_ID" != "$BUNDLE_ID" ]]; then
  echo "error: codesign Identifier is '${SIG_ID}', expected '${BUNDLE_ID}'." >&2
  echo "       macOS permissions (Documents access, App Management) will NOT persist." >&2
  echo "       Re-run codesign manually:" >&2
  echo "         sudo codesign --force --sign - -i '${BUNDLE_ID}' \\" >&2
  echo "           --timestamp=none --generate-entitlement-der \\" >&2
  echo "           --entitlements '${FORK_ENTITLEMENTS}' '${DEST}'" >&2
  exit 1
fi
echo "==> Signature identifier verified: ${SIG_ID}"

# Clear quarantine if something tagged it (shouldn't happen for a local build, but harmless).
$SUDO /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Installed:"
echo "    $DEST"

if [[ "$LAUNCH" -eq 1 ]]; then
  echo "==> Launching..."
  # Don't leak dev-shell pager overrides into cmux.
  env -u GIT_PAGER -u GH_PAGER open -g "$DEST"
fi
