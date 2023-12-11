#!/usr/bin/env bash

set -euxo pipefail

setup_network() {
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) == 0 ]]; then
        echo "ip forwarding not enabled"
        exit 1
    fi

    set +x
    local CONFIG=$(cat ./config.json)
    set -x

    sudo ip link add br0 type bridge
    sudo ip addr add 10.0.0.0/24 dev br0
    sudo ip link set up dev br0

    # Allows guests to reach internet
    sudo iptables -t nat -A POSTROUTING ! -o br0 --source 10.0.0.0/24 -j MASQUERADE 
    sudo iptables -A FORWARD -i br0 -j ACCEPT
    sudo iptables -A FORWARD -o br0 -j ACCEPT

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_NAME=$(echo $NODE | jq -r '.name')

        sudo ip tuntap add "${NODE_NAME}tap" mode tap
        sudo ip link set "${NODE_NAME}tap" up
        sudo ip link set "${NODE_NAME}tap" master br0
    done
}

setup_gateway() {
    if [[ ! -z "$(pidof dnsmasq)" ]]; then
        echo "dnsmasq already running"
        exit 1
    fi

    mkdir -p ./logs

    sudo -b \
        dnsmasq \
            --conf-file=./config/dnsmasq.conf \
            --no-daemon \
            --no-resolv \
            --no-hosts >> "./logs/dnsmasq.log" 2>&1
}

setup_network
setup_gateway
