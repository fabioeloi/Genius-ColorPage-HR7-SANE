#!/usr/bin/env bash
set -euo pipefail
set -o noclobber
export PATH=/opt/genius-hr7/bin:/opt/genius-hr7/lib:/usr/bin
export SANE_CONFIG_DIR=/opt/genius-hr7/etc/sane.d
[[ $# == 1 ]] || { echo 'Usage: Test-Scan.sh OUTPUT.png' >&2; exit 64; }
output=$1
[[ ! -e "$output" ]] || { echo 'Output already exists.' >&2; exit 64; }
scan_timeout_seconds=${SCAN_TIMEOUT_SECONDS:-180}
[[ "$scan_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo 'SCAN_TIMEOUT_SECONDS must be a positive integer.' >&2
  exit 64
}
scanimage -V
scanimage -L
mapfile -t devices < <(scanimage --formatted-device-list='%d%n')
[[ ${#devices[@]} == 1 && ${devices[0]} == plustek:* ]] || {
  echo 'Expected exactly one scanner using the private plustek configuration.' >&2
  exit 1
}
echo "Scanning ${devices[0]} at 300 dpi in Color..."
if timeout --signal=INT --kill-after=5s "${scan_timeout_seconds}s" \
    scanimage --device-name="${devices[0]}" --mode Color --resolution 300 --format=png > "$output"; then
  :
else
  status=$?
  if [[ $status == 124 || $status == 137 ]]; then
    echo "Scan timed out after ${scan_timeout_seconds}s; the scanner did not finish responding." >&2
  fi
  exit "$status"
fi
[[ -s "$output" ]]
echo "Scan saved: $output"
