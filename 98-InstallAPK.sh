#!/bin/sh

# Install the freshest EasySend*.apkx built by 00-Make.sh.
# Set DEVICE to an adb serial to target one of several attached devices.
DEVICE="${DEVICE:-}"

src=$(ls -t EasySend*.apkx 2>/dev/null | head -n1)
if [ -z "$src" ]; then
    echo "No EasySend*.apkx found. Run ./00-Make.sh first."
    exit 1
fi

dst="${src%x}"
cp "$src" "$dst"
echo "+++>>> $dst"

if [ -n "$DEVICE" ]; then
    adb -s "$DEVICE" install -r "$dst"
else
    adb install -r "$dst"
fi

rm -f "$dst"

sleep 3
