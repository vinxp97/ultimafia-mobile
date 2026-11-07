#!/bin/zsh
# Scripted Ghost game in the iOS Simulator (DEBUG fixture: -UMDiagReplay -UMDiagGhost <step>).
# Builds, boots a simulator, installs, launches each step, asserts the fixture's GHOSTCHECK line
# and saves a screenshot per step to $SHOTS/ghost-<step>-<tab>.png.
# Usage: scripts/ghost-sim-test.sh [simulator-udid]   (default: first available iPhone)
set -u
cd "${0:A:h}/.."
SHOTS=${SHOTS:-$HOME/Documents/XCode/umshots}
DD=${DD:-/tmp/um-ghost-dd}
BUNDLE=VCCCLLC.Ultimafia
mkdir -p "$SHOTS"
SIM=${1:-$(xcrun simctl list devices available | grep -E '^ +iPhone' | head -1 | grep -oE '[0-9A-F-]{36}')}
[[ -n "$SIM" ]] || { echo "No iPhone simulator available"; exit 2; }
echo "Simulator: $SIM"

xcodebuild -project Ultimafia.xcodeproj -scheme Ultimafia -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DD/Build/Products/Debug-iphonesimulator/Ultimafia.app"
[[ -d "$APP" ]] || { echo "FAIL build"; exit 1; }

xcrun simctl boot "$SIM" 2>/dev/null
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl install "$SIM" "$APP" || { echo "FAIL install"; exit 1; }

shot() { # name
  local out="$SHOTS/ghost-$1.png"
  xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1 \
    || xcrun simctl io "$SIM" screenshot --display=1 "$out" >/dev/null 2>&1
}

# Warm-up: the first launch after an install is a cold start and can miss the 7 s window.
xcrun simctl launch --terminate-running-process "$SIM" "$BUNDLE" -UMDiagReplay -UMDiagGhost night chat >/dev/null
sleep 10

pass=0; fail=0
step() { # step tab expected-substrings...
  local name=$1 tab=$2; shift 2
  local data=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
  local log="$data/Documents/ghostcheck.txt"
  rm -f "$log"
  xcrun simctl launch --terminate-running-process "$SIM" "$BUNDLE" \
    -UMDiagReplay -UMDiagGhost "$name" "$tab" >/dev/null
  sleep 7
  shot "$name-$tab"
  local line=$(grep -m1 GHOSTCHECK "$log" 2>/dev/null)
  local ok=1
  for want in "$@"; do [[ "$line" == *"$want"* ]] || { ok=0; echo "   missing: $want"; }; done
  if (( ok )); then pass=$((pass+1)); echo "PASS $name/$tab"; else fail=$((fail+1)); echo "FAIL $name/$tab"; fi
  echo "   $line"
}

step night     act  "stage=night" "meetings=Ghost" "clues=0" "len=5" "single=true" "ghost=true"
step clueother chat "stage=clue" "turn=Eve" "mine=false" "clues=11" "last=Dana:barn"
step clue      act  "stage=clue" "turn=Vinman" "mine=true" "clues=11" "rounds=11111111222 " "meetings=Give Clue" "word=horse"
step cluepass  chat "stage=clue" "turn=Eve" "mine=false" "clues=12" "last=Vinman:stallion"
step day       act  "stage=day" "clues=14" "rounds=11111111222222 " "meetings=Village" "last=Vinman:stallion"
step day       chat "stage=day" "clues=14"
step dusk      act  "stage=dusk" "meetings=Guess Word" "clues=14"
step over      act  "stage=over" "real=horse" "clues=14"
step over      chat "stage=over" "real=horse"
step replay      chat "stage=clue" "turn=Dana" "mine=false" "clues=10" "rounds=1111111122 " "last=Charlie:hooves"
step replay      act  "stage=clue" "turn=Dana" "clues=10"
step replaynight chat "stage=clue" "turn=Bob" "clues=8" "rounds=eeeeeeee " "word=horse"
step host        chat "ghost=false" "single=false" "panel=false" "clues=0" "meetings=Village"

echo "Passed $pass, failed $fail. Screenshots in $SHOTS/ghost-*.png"
(( fail == 0 ))
