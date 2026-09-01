#!/usr/bin/env bash

wait_for_agent_health() {
    local health_uri="$1"
    local timeout_seconds="$2"
    local retry_delay_seconds="$3"
    local deadline=$((SECONDS + timeout_seconds))

    while (( SECONDS < deadline )); do
        if curl --fail --silent --show-error \
            --connect-timeout 1 \
            --max-time 2 \
            "$health_uri" >/dev/null 2>&1; then
            return 0
        fi

        (( SECONDS < deadline )) || break
        sleep "$retry_delay_seconds"
    done

    return 1
}
