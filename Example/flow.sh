#!/bin/sh
# Runs the demo's whole flow on one simulator:
#
#   ./flow.sh <simulator id> [tag]
#
# It needs a localize.work API on this computer (BACKEND_PORT, serving
# published files under /cdn) and a helper that publishes the flow project's
# next release (CONTROL, with /state/<slug> and /publish-next/<slug>). The
# phases and the texts they expect are in LocalizeDemoUITests/FlowTests.swift.
# The simulator's own language should be English: where a language has no
# bundled text, the tests expect the app's English one.
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
stop_proxy() {
  if [ -n "$proxy" ]; then kill "$proxy" 2>/dev/null || true; fi
  proxy=
}
start_proxy() {
  python3 forward.py "$PROXY_PORT" "$BACKEND_PORT" &
  proxy=$!
  tries=0
  until curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$PROXY_PORT/cdn/$SLUG/latest.json" 2>/dev/null; do
    tries=$((tries + 1))
    # The forwarder ends at once when its port is taken, e.g. by one left
    # over from an earlier run; what answers there then is not ours to stop.
    if ! kill -0 "$proxy" 2>/dev/null; then
      echo "FAILED: could not listen on port $PROXY_PORT (PROXY_PORT)" >&2
      exit 1
    fi
    if [ "$tries" -ge 50 ]; then
      echo "FAILED: no release of $SLUG at http://127.0.0.1:$BACKEND_PORT/cdn (BACKEND_PORT, SLUG)" >&2
      exit 1
    fi
    sleep 0.2
  done
  sleep 0.5
  if ! kill -0 "$proxy" 2>/dev/null; then
    echo "FAILED: could not listen on port $PROXY_PORT (PROXY_PORT)" >&2
    exit 1
  fi
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

# The phases run what this builds, so a failed build stops the flow here.
built=0
build=$(xcodebuild build-for-testing -project LocalizeDemo.xcodeproj -scheme LocalizeDemo \
  -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$DERIVED" 2>&1) || built=$?
echo "$build" | grep -E "error:|TEST BUILD (SUCCEEDED|FAILED)" || true
if [ "$built" -ne 0 ]; then
  echo "FAILED: the build" >&2
  exit 1
fi

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
