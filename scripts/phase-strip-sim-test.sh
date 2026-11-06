#!/bin/zsh
# Phase strip windowing + instant switch screenshots (DEBUG: -UMDiagReplay -UMDiagTopBar).
# Boots iPhone Duo (or arg), installs Debug build, captures landscape+portrait many-* states.
set -u
cd "${0:A:h}/.."
SHOTS=${SHOTS:-$HOME/Documents/XCode/umshots/phase-strip}
DD=${DD:-/tmp/um-phase-strip-dd}
BUNDLE=VCCCLLC.Ultimafia
mkdir -p "$SHOTS"
SIM=${1:-$(xcrun simctl list devices available | grep -E 'iPhone Duo' | head -1 | grep -oE '[0-9A-F-]{36}')}
[[ -n "$SIM" ]] || { echo "No Duo simulator available"; exit 2; }
echo "Simulator: $SIM"

xcodebuild -project Ultimafia.xcodeproj -scheme Ultimafia -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build 2>&1 \
  | tee /tmp/um-phase-strip-build.log | grep -E "error:|warning:.*PhaseChrome|BUILD (SUCCEEDED|FAILED)"
APP="$DD/Build/Products/Debug-iphonesimulator/Ultimafia.app"
[[ -d "$APP" ]] || { echo "FAIL build"; tail -40 /tmp/um-phase-strip-build.log; exit 1; }

xcrun simctl boot "$SIM" 2>/dev/null
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl install "$SIM" "$APP" || { echo "FAIL install"; exit 1; }

# Warm-up cold start
xcrun simctl launch --terminate-running-process "$SIM" "$BUNDLE" \
  -UMDiagReplay -UMDiagTopBar many-latest >/dev/null
sleep 8

orient() { # landscape|portrait
  if [[ "$1" == landscape ]]; then
    xcrun simctl ui "$SIM" appearance --style dark >/dev/null 2>&1
    # Prefer XCUI orientation via AppleScript-free simctl status_bar? Use `simctl spawn` + notify.
    # Duo: set device orientation through simctl (iOS 17+):
    xcrun simctl ui "$SIM" --help >/dev/null 2>&1
    python3 - <<PY
import subprocess, sys
udid="$SIM"
# Try both spellings; ignore failures (orientation may already match).
for args in (
    ["xcrun","simctl","ui",udid,"orientation","landscapeLeft"],
    ["xcrun","simctl","ui",udid,"orientation","landscape"],
):
    subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
  else
    python3 - <<PY
import subprocess
udid="$SIM"
for args in (
    ["xcrun","simctl","ui",udid,"orientation","portrait"],
    ["xcrun","simctl","ui",udid,"orientation","portraitUpsideDown"],
):
    subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    break
PY
  fi
}

shot() {
  local out="$SHOTS/$1.png"
  # Duo has two LCDs; prefer the larger panel (display 3) then fall back.
  if xcrun simctl io "$SIM" screenshot --display=3 "$out" >/dev/null 2>&1; then
    :
  elif xcrun simctl io "$SIM" screenshot --display=1 "$out" >/dev/null 2>&1; then
    :
  else
    xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1 || true
  fi
  echo "shot $out ($( [[ -f $out ]] && wc -c <"$out" || echo 0 ) bytes)"
}

run_mode() { # mode orient-tag
  local mode=$1 tag=$2
  xcrun simctl launch --terminate-running-process "$SIM" "$BUNDLE" \
    -UMDiagReplay -UMDiagTopBar "$mode" >/dev/null
  sleep 6
  shot "${tag}-${mode}"
}

# Landscape unfolded Duo — the regression Vinman reported
orient landscape
sleep 1
for m in many-earliest many-middle many-latest many-post middle latest pregame; do
  run_mode "$m" duo-land
done

# Portrait too
orient portrait
sleep 1
for m in many-earliest many-middle many-latest; do
  run_mode "$m" duo-port
done

# Also iPhone portrait compact (GlassPhaseNavigator) on a phone sim if available
PHONE=$(xcrun simctl list devices available | grep -E 'iPhone 18 Pro Max' | head -1 | grep -oE '[0-9A-F-]{36}' || true)
if [[ -n "$PHONE" ]]; then
  xcrun simctl boot "$PHONE" 2>/dev/null
  xcrun simctl bootstatus "$PHONE" -b >/dev/null
  xcrun simctl install "$PHONE" "$APP" || true
  xcrun simctl launch --terminate-running-process "$PHONE" "$BUNDLE" \
    -UMDiagReplay -UMDiagTopBar many-middle >/dev/null
  sleep 6
  xcrun simctl io "$PHONE" screenshot "$SHOTS/iphone-port-many-middle.png" >/dev/null 2>&1
  echo "shot $SHOTS/iphone-port-many-middle.png"
fi

# iPad wide header
IPAD=$(xcrun simctl list devices available | grep -E 'iPad Pro 13-inch' | head -1 | grep -oE '[0-9A-F-]{36}' || true)
if [[ -n "$IPAD" ]]; then
  xcrun simctl boot "$IPAD" 2>/dev/null
  xcrun simctl bootstatus "$IPAD" -b >/dev/null
  xcrun simctl install "$IPAD" "$APP" || true
  xcrun simctl launch --terminate-running-process "$IPAD" "$BUNDLE" \
    -UMDiagReplay -UMDiagTopBar many-middle >/dev/null
  sleep 6
  xcrun simctl io "$IPAD" screenshot "$SHOTS/ipad-many-middle.png" >/dev/null 2>&1
  echo "shot $SHOTS/ipad-many-middle.png"
fi

echo "Screenshots in $SHOTS"
ls -la "$SHOTS" | tail -30
