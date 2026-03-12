#!/usr/bin/env sh

# Helper for testing ProcessRunner cancellation escalation.
# It ignores SIGTERM so the app's 3-second watchdog must escalate to SIGKILL.

set -eu

trap '' TERM

printf '%s\n' "fake-ffmpeg-hang: started and ignoring SIGTERM" >&2
printf '%s\n' "fake-ffmpeg-hang: args: $*" >&2

while :; do
    sleep 1
done
