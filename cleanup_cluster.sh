#!/usr/bin/env bash

CONFIG=$(cat ./config.json)

set -eux

cleanup_network() {
    set +e

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_NAME=$(echo $NODE | jq -r '.name')

        sudo ip link delete "${NODE_NAME}tap"
    done

    sudo ip link delete br0
    sudo iptables -t nat -D POSTROUTING ! -o br0 --source 10.0.0.0/24 -j MASQUERADE

    set -e
}

cleanup_gateway() {
    if [[ -f ./build/dnsmasq.pid ]]; then
        set +e
        kill "$(cat ./build/dnsmasq.pid)"
        set -e
    fi
}

wait_for() {
    echo "Waiting for $1"
    shift
    while true; do
        kubectl wait $@
        if [[ $? = 0 ]]; then
            break
        fi
    done
}

cleanup_gateway
cleanup_network
