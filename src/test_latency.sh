#!/bin/bash

# Function to perform latency test for a single IP address
test_latency() {
    local ip="$1"
    ping_output=$(ping -c 3 "$ip" 2>&1)
    latency=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    if [ -z "$latency" ]; then
        latency="N/A"
    fi
    echo "$ip $latency"
}

# If the script is called with an IP, test latency
if [ -n "$1" ]; then
    test_latency "$1"
fi