#!/bin/zsh
# Generates synthetic test media into TestMedia/ (gitignored) and adds it to a simulator.
# Usage: Scripts/seed_simulator.sh [simulator-udid]   (default: booted simulator)
# Requires ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="${1:-booted}"
OUT=TestMedia
WORK=$(mktemp -d)
mkdir -p "$OUT"

colors=(red orange gold green teal blue)
for i in {1..6}; do
  ffmpeg -loglevel error -y -f lavfi -i "color=c=${colors[$i]}:s=1200x1600" \
    -vf "drawgrid=w=100:h=100:t=4:c=white@0.5,drawbox=x=$((i*120)):y=$((i*150)):w=300:h=300:c=white:t=fill" \
    -frames:v 1 "$WORK/p$i.png"
  swift Scripts/make_exif_photo.swift "$WORK/p$i.png" "$OUT/photo_$i.jpg" "$i"
done

ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=1080x1920:d=5:r=30" -f lavfi -i "sine=frequency=440:duration=5" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/test_video.mp4"

ffmpeg -loglevel error -y -i "$OUT/test_video.mp4" -t 2.5 -an -c:v libx264 -pix_fmt yuv420p "$WORK/clip.mp4"
ffmpeg -loglevel error -y -ss 1 -i "$WORK/clip.mp4" -frames:v 1 "$WORK/still.jpg"
swiftc -O -o "$WORK/mklive" Scripts/make_live_photo.swift 2>/dev/null
"$WORK/mklive" "$WORK/still.jpg" "$WORK/clip.mp4" "$OUT/live_1.JPG" "$OUT/live_1.MOV"

xcrun simctl addmedia "$UDID" "$OUT"/photo_*.jpg "$OUT/test_video.mp4" "$OUT/live_1.JPG" "$OUT/live_1.MOV"
xcrun simctl privacy "$UDID" grant photos com.example.Cull
echo "Seeded $UDID"
