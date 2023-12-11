#!/usr/bin/env bash

set -euxo pipefail

cleanup_network() {
    set +x
    local CONFIG=$(cat ./config.json)
    set -x

    set +e

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_NAME=$(echo $NODE | jq -r '.name')

        sudo ip link delete "${NODE_NAME}tap"
    done

    sudo iptables -t nat -D POSTROUTING ! -o br0 --source 10.0.0.0/24 -j MASQUERADE
    sudo iptables -D FORWARD -i br0 -j ACCEPT
    sudo iptables -D FORWARD -o br0 -j ACCEPT

    sudo ip link delete br0

    set -e
}

cleanup_gateway() {
    local PID="$(pidof dnsmasq)"
    if [[ ! -z "$PID" ]]; then
        sudo kill "$PID"
    fi
}

cleanup_gateway
cleanup_network
