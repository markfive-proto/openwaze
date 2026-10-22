#!/usr/bin/env bash
# Records the app walkthrough to demo/openwaze-demo.mp4 (#52). `make demo`.
#
# Starts the reports server with an in-memory DB, seeds 5 reports and synthetic
# traffic along the KLCC to Pavilion KL drive, boots a throwaway simulator, builds
# and installs the app, records the screen while the DemoTour UI test drives the
# UI, and replays the GPX once the test has tapped Start. Needs Xcode, Node 22.18+,
# network (Photon, OSRM, map tiles); ffmpeg is optional (compresses the video).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PORT=${PORT:-8797} # not 8787, so a running dev server is left alone
GPX=${GPX:-App/TestData/KLCC-to-Pavilion.gpx}
SPEED=${SPEED:-16} # m/s for the replay; about 55 km/h
DEVICE_TYPE=${DEMO_DEVICE_TYPE:-iPhone 17 Pro}
OUT=demo/openwaze-demo.mp4
BUNDLE=org.openwaze.app
API="http://localhost:$PORT"
KLCC=3.1579,101.7116
XCODEBUILD=(xcodebuild -project OpenWaze.xcodeproj -scheme OpenWazeDemo -derivedDataPath build)

work=$(mktemp -d)
server_pid=""
rec_pid=""
sim=""

cleanup() {
  status=$?
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
  [ -n "$rec_pid" ] && kill -INT "$rec_pid" 2>/dev/null
  if [ -n "$sim" ]; then
    xcrun simctl location "$sim" clear 2>/dev/null || true
    xcrun simctl shutdown "$sim" 2>/dev/null || true
    xcrun simctl delete "$sim" 2>/dev/null || true
  fi
  [ "$status" -eq 0 ] || { echo "demo: failed; xcodebuild log:"; tail -40 "$work/xcodebuild.log" 2>/dev/null; }
  rm -rf "$work"
}
trap cleanup EXIT

if pgrep -x xcodebuild >/dev/null; then
  echo "demo: another xcodebuild is running; try again when it is done." >&2
  exit 1
fi
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "demo: port $PORT is in use; stop that server or set PORT." >&2
  exit 1
fi
[ -d server/node_modules ] || { echo "demo: run 'npm ci' in server/ first." >&2; exit 1; }

# --- server -------------------------------------------------------------------
echo "demo: server on $API (in-memory DB)"
(cd server && DB_PATH=:memory: PORT="$PORT" exec node src/server.ts) >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -sf "$API/reports?minLat=3&minLng=101&maxLat=3.3&maxLng=101.9" >/dev/null && break
  sleep 0.2
done
curl -sf "$API/reports?minLat=3&minLng=101&maxLat=3.3&maxLng=101.9" >/dev/null || { echo "demo: server did not start"; cat "$work/server.log"; exit 1; }

# --- seed: 5 reports and 3+ trips per cell along the route --------------------
# "lat lon" per GPX point, in route order.
grep -oE 'lat="[^"]+" lon="[^"]+"' "$GPX" | sed -E 's/lat="([^"]+)" lon="([^"]+)"/\1 \2/' >"$work/points"
n=$(wc -l <"$work/points")
i=0
for type in police accident hazard traffic closure; do
  i=$((i + 1))
  read -r lat lon < <(sed -n "$((n * i / 6))p" "$work/points")
  curl -sf -o /dev/null -X POST "$API/reports" -H 'content-type: application/json' \
    -d "{\"type\":\"$type\",\"lat\":$lat,\"lng\":$lon,\"deviceId\":\"demo-seed-$i\"}"
done
echo "demo: seeded 5 reports"

# One sample per 110 m cell and heading: jam on the 2nd fifth of the route, slow on the 4th, else free.
awk '
  { lat[NR] = $1; lon[NR] = $2 }
  END {
    pi = atan2(0, -1)
    for (i = 1; i < NR; i++) {
      dlon = (lon[i+1] - lon[i]) * pi / 180
      y = sin(dlon) * cos(lat[i+1] * pi / 180)
      x = cos(lat[i] * pi / 180) * sin(lat[i+1] * pi / 180) - sin(lat[i] * pi / 180) * cos(lat[i+1] * pi / 180) * cos(dlon)
      heading = (atan2(y, x) * 180 / pi + 360) % 360
      cell = sprintf("%.3f %.3f %d", lat[i], lon[i], int((heading + 22.5) / 45) % 8 * 45)
      if (cell in seen) continue
      seen[cell] = 1
      f = i / NR
      speed = (f > 0.2 && f < 0.4) ? 8 : (f > 0.6 && f < 0.8) ? 28 : 55
      print cell, speed
    }
  }' "$work/points" >"$work/cells"
t=$(date -u +%Y-%m-%dT%H:%M:00Z)
for trip in 1 2 3 4; do
  trip_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  # At most 30 samples per POST; speeds jittered per trip so the median is still in band.
  split -l 30 "$work/cells" "$work/chunk."
  for chunk in "$work"/chunk.*; do
    samples=$(awk -v j="$trip" -v t="$t" '{
      printf "%s{\"lat\":%s,\"lng\":%s,\"heading\":%s,\"speedKmh\":%s,\"t\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2, $3, $4 + j - 2, t
    }' "$chunk")
    curl -sf -o /dev/null -X POST "$API/probes" -H 'content-type: application/json' \
      -d "{\"tripId\":\"$trip_id\",\"samples\":[$samples]}"
    rm "$chunk"
  done
done
echo "demo: seeded traffic for $(wc -l <"$work/cells" | tr -d ' ') cells x 4 trips"

# --- simulator ----------------------------------------------------------------
sim=$(xcrun simctl create "OpenWaze Demo" "$DEVICE_TYPE")
echo "demo: simulator $sim ($DEVICE_TYPE)"
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

echo "demo: building"
"${XCODEBUILD[@]}" -destination "id=$sim" build-for-testing >"$work/xcodebuild.log" 2>&1
xcrun simctl install "$sim" build/Build/Products/Debug-iphonesimulator/OpenWaze.app
xcrun simctl privacy "$sim" grant location "$BUNDLE"
xcrun simctl location "$sim" set "$KLCC"

# --- record -------------------------------------------------------------------
mkdir -p demo
xcrun simctl io "$sim" recordVideo --codec=h264 --force "$work/raw.mov" &
rec_pid=$!
sleep 2

echo "demo: running DemoTour"
TEST_RUNNER_DEMO_MARKER="$work/started" TEST_RUNNER_DEMO_API_URL="$API" "${XCODEBUILD[@]}" -destination "id=$sim" test-without-building \
  -only-testing:OpenWazeDemo/DemoTour >>"$work/xcodebuild.log" 2>&1 &
test_pid=$!
# The test writes the marker right after tapping Start; then the drive begins.
while [ ! -e "$work/started" ] && kill -0 "$test_pid" 2>/dev/null; do sleep 0.5; done
if [ -e "$work/started" ]; then
  echo "demo: driving $GPX at $SPEED m/s"
  sed "s/ /,/" "$work/points" | xcrun simctl location "$sim" start --speed="$SPEED" - || true
fi
wait "$test_pid"

kill -INT "$rec_pid"
wait "$rec_pid" || true
rec_pid=""

if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -y -i "$work/raw.mov" -vf 'scale=-2:1080' -c:v libx264 -crf 26 -preset medium \
    -pix_fmt yuv420p -movflags +faststart "$OUT"
else
  OUT=${OUT%.mp4}.mov
  mv "$work/raw.mov" "$OUT"
  echo "demo: ffmpeg not found, saved uncompressed"
fi
echo "demo: wrote $OUT"
