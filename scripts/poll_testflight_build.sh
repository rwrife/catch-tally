#!/usr/bin/env bash
# Poll the App Store Connect API for a TestFlight build's processing state.
# Exits 0 once processingState=VALID (usable in TestFlight), non-zero on
# FAILED/INVALID or timeout. Prints the real API response at each poll —
# never fabricates a completion state.
set -euo pipefail

usage() {
  echo "Usage: poll_testflight_build.sh --bundle-id ID --version VERSION --build-number NUM --jwt-script PATH --key-id ID --issuer-id ID --key-path PATH [--timeout-seconds N] [--interval-seconds N]" >&2
}

TIMEOUT_SECONDS=1800
INTERVAL_SECONDS=30

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --version) APP_VERSION="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --jwt-script) JWT_SCRIPT="$2"; shift 2 ;;
    --key-id) KEY_ID="$2"; shift 2 ;;
    --issuer-id) ISSUER_ID="$2"; shift 2 ;;
    --key-path) KEY_PATH="$2"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --interval-seconds) INTERVAL_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

for required in BUNDLE_ID APP_VERSION BUILD_NUMBER JWT_SCRIPT KEY_ID ISSUER_ID KEY_PATH; do
  if [ -z "${!required:-}" ]; then
    echo "missing required argument for $required" >&2
    usage
    exit 1
  fi
done

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))

jwt=$(ruby "$JWT_SCRIPT" --key-id "$KEY_ID" --issuer-id "$ISSUER_ID" --key-path "$KEY_PATH")
# App Store Connect uses JSON:API filter[...] query parameters. Disable curl
# URL globbing so square brackets are sent literally instead of parsed as ranges.
app_response=$(curl -g -sS \
  -H "Authorization: Bearer $jwt" \
  "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1")
echo "--- App Store Connect app lookup response ---"
echo "$app_response"
app_id=$(echo "$app_response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('errors'):
    raise SystemExit('app lookup returned errors: ' + json.dumps(data['errors']))
apps = data.get('data', [])
if len(apps) != 1:
    raise SystemExit('expected exactly one App Store Connect app')
print(apps[0]['id'])
")

while true; do
  jwt=$(ruby "$JWT_SCRIPT" --key-id "$KEY_ID" --issuer-id "$ISSUER_ID" --key-path "$KEY_PATH")

  response=$(curl -g -sS \
    -H "Authorization: Bearer $jwt" \
    "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=${app_id}&filter[version]=${BUILD_NUMBER}&filter[preReleaseVersion.version]=${APP_VERSION}&sort=-uploadedDate&limit=10")

  echo "--- App Store Connect builds response ---"
  echo "$response"

  state=$(echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
target_build = '$BUILD_NUMBER'
for item in data.get('data', []):
    attrs = item.get('attributes', {})
    if str(attrs.get('version')) == target_build:
        print(attrs.get('processingState', 'UNKNOWN'))
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")

  echo "Build $BUILD_NUMBER processingState: $state"

  case "$state" in
    VALID)
      echo "TestFlight build $BUILD_NUMBER processed successfully (VALID)."
      exit 0
      ;;
    INVALID|FAILED)
      echo "::error::TestFlight build $BUILD_NUMBER processing failed: $state" >&2
      exit 1
      ;;
    PROCESSING|NOT_FOUND)
      # Still in flight (or not yet listed) — keep polling until deadline.
      ;;
    *)
      # PARSE_ERROR or an unlisted enum value: report the raw response above
      # and keep polling; the deadline keeps this bounded.
      ;;
  esac

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "::error::Timed out after ${TIMEOUT_SECONDS}s waiting for TestFlight build $BUILD_NUMBER (last state: $state)" >&2
    exit 1
  fi

  sleep "$INTERVAL_SECONDS"
done
