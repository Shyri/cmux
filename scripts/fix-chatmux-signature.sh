#!/usr/bin/env bash
# One-shot repair for /Applications/Chatmux.app when macOS keeps
# re-prompting for Documents / App Management permissions.
#
# Root cause: the Release cmux.app from DerivedData is built with
# Identifier=cmux + flags=linker-signed, and `codesign --force` alone
# does NOT override that — it needs --remove-signature first. Without
# this fix the TCC database keys grants against Identifier=cmux, which
# collides with the official cmux app, and every launch re-prompts.
#
# This script:
#   1. Removes ALL existing signatures (outer + nested), deepest first
#   2. Re-signs every nested bundle ad-hoc
#   3. Re-signs the outer bundle pinning Identifier=com.cmuxterm.app.fork
#   4. Verifies the outer Identifier actually took
#   5. Resets the TCC database entries for the fork bundle id so the
#      next launch creates a clean grant
#
# Run with sudo because /Applications is system-owned. The codesign
# steps need root to write back the new signature inline. tccutil
# reset is per-user and doesn't need sudo (it acts on the current
# user's TCC db).

set -euo pipefail

APP="/Applications/Chatmux.app"
BUNDLE_ID="com.cmuxterm.app.fork"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/cmux.entitlements"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP does not exist. Install it first with ./scripts/install-fork.sh" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements file $ENTITLEMENTS not found" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "==> Re-running with sudo..."
  exec sudo "$0" "$@"
fi

# Quit any running instance via the dock-server route instead of pkill.
# (We *prompt* before killing, so the user can save state.)
RUNNING_PID="$(pgrep -f "$APP/Contents/MacOS/cmux" 2>/dev/null | head -1 || true)"
if [[ -n "$RUNNING_PID" ]]; then
  echo "==> Chatmux is running (pid $RUNNING_PID)."
  echo "    The signature can't be replaced while the binary is in use."
  read -r -p "    Quit Chatmux now? [y/N] " yn
  case "$yn" in
    [yY]|[yY][eE][sS])
      osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
      sleep 0.5
      pkill -f "$APP/Contents/MacOS/cmux" 2>/dev/null || true
      sleep 0.3
      ;;
    *)
      echo "    Aborted. Quit Chatmux yourself, then re-run this script." >&2
      exit 1
      ;;
  esac
fi

# Build a depth-first list of nested signable bundles.
NESTED=()
while IFS= read -r -d '' p; do
  [[ "$p" == "$APP" ]] && continue
  NESTED+=("$p")
done < <(/usr/bin/find "$APP" \
  \( -name "*.app" -o -name "*.appex" -o -name "*.xpc" \
     -o -name "*.framework" -o -name "*.plugin" -o -name "*.bundle" \) \
  -print0)

# Sort by path length descending so the deepest bundle is signed first.
NESTED_SORTED=()
while IFS= read -r line; do
  NESTED_SORTED+=("$line")
done < <(printf '%s\n' "${NESTED[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

echo
echo "==> Step 1/5: Removing existing signatures (deepest first)..."
for nested in "${NESTED_SORTED[@]}"; do
  echo "    - ${nested#$APP/}"
  /usr/bin/codesign --remove-signature "$nested" 2>/dev/null || true
done
echo "    - <outer bundle>"
/usr/bin/codesign --remove-signature "$APP" 2>/dev/null || true

echo
echo "==> Step 2/5: Re-signing nested bundles ad-hoc..."
for nested in "${NESTED_SORTED[@]}"; do
  echo "    + ${nested#$APP/}"
  /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$nested"
done

echo
echo "==> Step 3/5: Re-signing outer bundle with Identifier=$BUNDLE_ID..."
/usr/bin/codesign \
  --force \
  --sign - \
  -i "$BUNDLE_ID" \
  --timestamp=none \
  --generate-entitlement-der \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

echo
echo "==> Step 4/5: Verifying signature identity..."
SIG_ID="$(/usr/bin/codesign -dvv "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
SIG_FLAGS="$(/usr/bin/codesign -dvv "$APP" 2>&1 | sed -n 's/^.*flags=//p' | head -1)"
echo "    Identifier: $SIG_ID"
echo "    Flags:      $SIG_FLAGS"
if [[ "$SIG_ID" != "$BUNDLE_ID" ]]; then
  echo "    ERROR: Identifier mismatch. Expected $BUNDLE_ID." >&2
  exit 1
fi
if [[ "$SIG_FLAGS" == *"linker-signed"* ]]; then
  echo "    ERROR: linker-signed flag still present — re-signing didn't take." >&2
  exit 1
fi
echo "    OK: signature is clean and pinned to $BUNDLE_ID."

echo
echo "==> Step 5/5: Resetting TCC entries for $BUNDLE_ID..."
# tccutil writes to the *invoking* user's TCC db, not root's. Drop to
# the original user (SUDO_USER) so the reset hits the right db.
TCC_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
sudo -u "$TCC_USER" tccutil reset All "$BUNDLE_ID" 2>&1 | sed 's/^/    /' || true

echo
echo "==> Done."
echo "    Next steps:"
echo "      1. Launch /Applications/Chatmux.app"
echo "      2. macOS will prompt ONCE for each TCC permission Chatmux needs."
echo "      3. Grant them. Quit and re-launch — the prompts should NOT come back."
echo
echo "    If they do come back, the dock tile plugin is the next suspect."
echo "    Check it with:  codesign -dvv \"$APP/Contents/PlugIns/CmuxDockTilePlugin.plugin\""
