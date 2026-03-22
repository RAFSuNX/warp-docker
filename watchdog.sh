#!/bin/bash

# WARP Connection Watchdog
# Monitors WARP connectivity and attempts reconnection on failure.
# Runs as a background process started by entrypoint.sh when WARP_WATCHDOG is set.

INTERVAL="${WARP_WATCHDOG_INTERVAL:-30}"
MAX_RETRIES="${WARP_WATCHDOG_MAX_RETRIES:-5}"
RETRY_DELAY=10

while true; do
    sleep "$INTERVAL"

    # check connectivity using the same method as the health check
    if curl -fsS --max-time 5 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -qE "warp=(plus|on)"; then
        continue
    fi

    echo "[watchdog] WARP connection lost, attempting reconnect..."

    retry=0
    while [ "$retry" -lt "$MAX_RETRIES" ]; do
        warp-cli --accept-tos connect 2>/dev/null || true
        sleep "$RETRY_DELAY"

        if curl -fsS --max-time 5 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -qE "warp=(plus|on)"; then
            echo "[watchdog] WARP reconnected successfully"
            break
        fi

        retry=$((retry + 1))
        echo "[watchdog] Reconnect attempt $retry/$MAX_RETRIES failed"
    done

    if [ "$retry" -eq "$MAX_RETRIES" ]; then
        echo "[watchdog] WARNING: Failed to reconnect after $MAX_RETRIES attempts. Will retry next interval."
    fi
done
