#!/usr/bin/env bash

set -euo pipefail

generate_k0sctl_config() {
    local CONFIG=$(cat ./config.json)
    local SSH_PORT=$(echo $CONFIG | jq -cr '.ssh.port')
    local SSH_IDENTITY=$(eval echo $(echo $CONFIG | jq -cr '.ssh.identity'))

    cat ./config/k0sctl_head.yaml

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        local NODE_IP=$(echo $NODE | jq -r '.ip')
        local NODE_ROLE=$(echo $NODE | jq -r '.role')

        if [[ "$NODE_ROLE" == "controller" ]] || [[ "$NODE_ROLE" == "worker" ]]; then
            cat <<EOF
  - role: ${NODE_ROLE}
    installFlags:
    - --debug
    ssh:
      address: ${NODE_IP}
      user: root
      port: ${SSH_PORT}
      keyPath: ${SSH_IDENTITY}
EOF
        fi
    done

    K0S_VERSION=$(echo $CONFIG | jq -cr '.k0s_version') \
        envsubst < ./config/k0sctl_tail.yaml
}

generate_k0sctl_config
