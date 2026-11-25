#!/bin/sh
# Runs the demo's whole flow on one simulator:
#
#   ./flow.sh <simulator id> [tag]
#
# It needs a localize.work API on this computer (BACKEND_PORT, serving
# published files under /cdn) and a helper that publishes the flow project's
# next release (CONTROL, with /state/<slug> and /publish-next/<slug>). The
# phases and the texts they expect are in LocalizeDemoUITests/FlowTests.swift.
#
# Set REAL_SLUG to a published project to also read it from the default CDN.
set -eu
cd "$(dirname "$0")"

SIMULATOR=${1:?usage: flow.sh <simulator id> [tag]}
TAG=${2:-ios}
BACKEND_PORT=${BACKEND_PORT:-3411}
PROXY_PORT=${PROXY_PORT:-3421}
CONTROL=${CONTROL:-http://127.0.0.1:3412}
SLUG=${SLUG:-demo-ios}
SHOTS=${SHOTS:-$PWD/flow-shots}
DERIVED=${DERIVED:-$PWD/.flow-build}
BUNDLE_ID=work.localize.demo

mkdir -p "$SHOTS"
proxy=
stop_proxy() { [ -n "$proxy" ] && kill "$proxy" 2>/dev/null; proxy=; }
start_proxy() {
  python3 forward.py "$PROXY_PORT" "$BACKEND_PORT" &
  proxy=$!
  until curl -s -o /dev/null "http://127.0.0.1:$PROXY_PORT/cdn/$SLUG/latest.json"; do sleep 0.2; done
}
trap stop_proxy EXIT

failed=
phase() {
  echo "== $1"
  output=$(TEST_RUNNER_FLOW_CDN="http://127.0.0.1:$PROXY_PORT/cdn" TEST_RUNNER_FLOW_CONTROL="$CONTROL" \
    TEST_RUNNER_FLOW_SLUG="$SLUG" TEST_RUNNER_FLOW_SHOTS="$SHOTS" TEST_RUNNER_FLOW_TAG="$TAG" \
    TEST_RUNNER_FLOW_REAL_SLUG="${REAL_SLUG:-}" \
    xcodebuild test-without-building -project LocalizeDemo.xcodeproj -scheme LocalizeDemo \
      -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$DERIVED" \
      -only-testing:"LocalizeDemoUITests/FlowTests/$1" 2>&1) || true
  echo "$output" | grep -E "error:|Test Case .*(passed|failed|skipped)" || true
  echo "$output" | grep -q "TEST EXECUTE SUCCEEDED" || failed="$failed $1"
}

xcodebuild build-for-testing -project LocalizeDemo.xcodeproj -scheme LocalizeDemo \
  -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$DERIVED" 2>&1 |
  grep -E "error:|TEST BUILD (SUCCEEDED|FAILED)"

# A fresh install: nothing saved on the device.
xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl uninstall "$SIMULATOR" "$BUNDLE_ID" 2>/dev/null || true

phase test1BundledWhileUnreachable
start_proxy
phase test2DownloadsTheRelease
phase test3ChangesLanguage
phase test4aNextLaunchWaits
phase test4bImmediatelyChangesTheScreen
stop_proxy
phase test5SavedReleaseWhileUnreachable
if [ -n "${REAL_SLUG:-}" ]; then phase test6RealCDN; fi
echo "screenshots in $SHOTS"
if [ -n "$failed" ]; then
  echo "FAILED:$failed"
  exit 1
fi
echo "every phase passed"
