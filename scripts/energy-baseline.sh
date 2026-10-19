#!/bin/bash
# Usage: ./scripts/energy-baseline.sh [seconds]
#
# Samples Recordly CPU usage for N seconds (default 60) and prints the average.
# Run during a recording to capture the baseline; run again after perf changes
# and compare. With sudo, also reports powermetrics energy impact.
set -euo pipefail

DURATION="${1:-60}"
PID=$(pgrep -x Recordly | head -1) || { echo "Recordly not running"; exit 1; }

echo "Sampling Recordly (pid $PID) for ${DURATION}s..."
SAMPLES=0
TOTAL=0
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
    CPU=$(ps -o %cpu= -p "$PID" | tr -d ' ' || echo 0)
    TOTAL=$(echo "$TOTAL + ${CPU:-0}" | bc)
    SAMPLES=$((SAMPLES + 1))
    sleep 1
done

echo "Average CPU: $(echo "scale=1; $TOTAL / $SAMPLES" | bc)% over $SAMPLES samples"

if [ "$(id -u)" = "0" ]; then
    echo "powermetrics (task energy):"
    powermetrics --samplers tasks -i $((DURATION * 1000)) -n 1 2>/dev/null \
        | grep -i -A2 recordly || true
else
    echo "(run with sudo for powermetrics energy impact)"
fi
