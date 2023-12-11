#!/usr/bin/env bash

set -euxo pipefail

reset_nodes() {
    set +x
    local CONFIG=$(cat ./config.json)
    set -x
    
    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        set +x
        local NODE_NAME=$(echo $NODE | jq -r '.name')
        local NODE_DISK="./build/disk/${NODE_NAME}.qcow2"
        set -x

        if [[ -f "$NODE_DISK" ]]; then
            rm $NODE_DISK
        fi
    done
}

reset_nodes
