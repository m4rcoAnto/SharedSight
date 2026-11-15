#!/bin/bash
# Run on the Mac (needs Xcode):  ./Scripts/verify.sh
# Writes build/test logs next to the project so results can be inspected and reported honestly.
cd "$(dirname "$0")/.." || exit 1
mkdir -p Logs
if command -v node >/dev/null && [ -d Server/node_modules ]; then
  echo "== node --test (hub: fusion, shadow zones, prediction, HTTP, simulated demo) =="
  ( cd Server && node --test 2>&1 ) | tee Logs/server-tests.log | grep -E "^# (tests|pass|fail)|^not ok"
fi
echo "== swift test (SharedSightCore, runs on the Mac, not on an iPhone) =="
( cd SharedSightCore && swift test 2>&1 ) | tee Logs/core-tests.log | tail -n 40
echo "== xcodebuild (iOS Simulator, compile check only — NOT device validation) =="
xcodebuild -project SharedSight.xcodeproj -scheme SharedSight -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee Logs/app-build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" | sort -u | tail -n 60
echo "Logs written to Logs/core-tests.log and Logs/app-build.log"
