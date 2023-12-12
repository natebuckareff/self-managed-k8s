#!/usr/bin/env bash

set -euxo pipefail

start_nodes() {
    set +x
    local CONFIG=$(cat ./config.json)
    local BASE_IMAGE=$(echo $CONFIG | jq -cr '.base_image')
    local SSH_PORT=$(echo $CONFIG | jq -cr '.ssh.port')
    local SSH_IDENTITY=$(eval echo $(echo $CONFIG | jq -cr '.ssh.identity'))
    set -x

    if [[ ! -f "./build/$BASE_IMAGE" ]]; then
        wget -P build https://cloud.debian.org/images/cloud/bookworm/latest/$BASE_IMAGE
    fi

    # Substitute `SSH_KEY` info `cloud_init.yaml` and then pipe that into
    # `cloud-localds` to generate the seed ISO file
    SSH_KEY=$(cat "${SSH_IDENTITY}.pub") envsubst < ./config/cloud_init.yaml \
        | cloud-localds -v ./build/seed.iso -

    mkdir -p ./logs

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        local NODE_NAME=$(echo $NODE | jq -r '.name')
        local NODE_MAC=$(echo $NODE | jq -r '.mac')
        local NODE_DISK="./build/disk/${NODE_NAME}.qcow2"

        echo "Starting node ${NODE_NAME}"

        if [[ ! -f "$NODE_DISK" ]]; then
            mkdir -p "$(dirname $NODE_DISK)"
            cp "./build/$BASE_IMAGE" "$NODE_DISK"
            qemu-img resize "$NODE_DISK" 10G
        fi

        echo "Redirecting output to ./logs/${NODE_NAME}.log"
        echo "Redirecting serial output to ./logs/${NODE_NAME}.serial.log"

        sudo -b \
            qemu-system-x86_64 \
                -name "$NODE_NAME" \
                -m 2G \
                -smp 2 \
                -device "virtio-net-pci,netdev=${NODE_NAME}tap,mac=${NODE_MAC}" \
                -netdev "tap,id=${NODE_NAME}tap,ifname=${NODE_NAME}tap,script=no" \
                -drive "file=./${NODE_DISK},if=virtio,cache=writeback,discard=ignore,format=qcow2" \
                -drive "file=./build/seed.iso,media=cdrom" \
                -boot d \
                -serial file:./logs/${NODE_NAME}.serial.log \
                -machine type=pc,accel=kvm >> "./logs/${NODE_NAME}.log" 2>&1

    done

    local INSTALL_K0S=false

    # Wait for nodes to come online
    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        local NODE_IP=$(echo $NODE | jq -r '.ip')
        local NODE_ROLE=$(echo $NODE | jq -r '.role')

        ssh-keygen -R "$NODE_IP"

        while true; do
            echo "$NODE_IP: Waiting for SSH"
            sleep 1
            if temp_ssh "root@$NODE_IP" "echo Ready: $NODE_IP"; then
                break
            fi
        done

        if [[ "$NODE_ROLE" == "controller" ]] || [[ "$NODE_ROLE" == "worker" ]]; then
            # Check if k0s service is installed and wait for it to start
            if temp_ssh "root@$NODE_IP" "systemctl is-enabled k0s$NODE_ROLE"; then
                echo "$NODE_IP: k0s$NODE_ROLE.service is already installed"
                while true; do
                    echo "$NODE_IP: Waiting for k0s$NODE_ROLE.service to start"
                    sleep 5
                    if temp_ssh "root@$NODE_IP" "systemctl is-active k0s$NODE_ROLE"; then
                        break
                    fi
                done
            else
                echo "$NODE_IP: k0s$NODE_ROLE.service not installed"
                INSTALL_K0S=true
            fi

            # Checkif k0s binary is installed, and if not upload it from cache
            if ! temp_ssh "root@$NODE_IP" "test -f /usr/local/bin/k0s"; then
                echo "$NODE_IP: K0S binary not installed"

                download_k0s

                local K0S_VERSION=$(echo $CONFIG | jq -cr '.k0s_version')
                local K0S_BIN_FILE="k0s-${K0S_VERSION}-amd64"

                temp_scp "./build/$K0S_BIN_FILE" "root@$NODE_IP:/usr/local/bin/k0s"
                temp_ssh "root@$NODE_IP" "chown root:root /usr/local/bin/k0s"
                temp_ssh "root@$NODE_IP" "chmod 750 /usr/local/bin/k0s"

                echo "$NODE_IP: Installed k0s binary"
            fi
        fi

        if [[ "$NODE_ROLE" == "lb" ]]; then
            temp_ssh "root@$NODE_IP" "apt-get update -y"
            temp_ssh "root@$NODE_IP" "apt-get install -y haproxy=2.6.\*"
        fi
    done

    if [[ $INSTALL_K0S == true ]]; then
        set +e

        echo "K0S not installed on all or some nodes; installing"

        # Install k0s on nodes
        ./generate_k0sctl_config.sh \
            | tee ./build/k0sctl.yaml \
            | k0sctl --debug apply --config -

        # Get and merge kubeconfig
        k0sctl kubeconfig --config ./build/k0sctl.yaml > ./build/kubeconfig
        mkdir -p ~/.kube
        KUBECONFIG="./build/kubeconfig" kubectl config view --flatten > ~/.kube/config

        set -e
    fi
}

download_k0s() {
    local K0S_VERSION=$(echo $CONFIG | jq -cr '.k0s_version')
    local K0S_BIN_PREFIX_URL="https://github.com/k0sproject/k0s/releases/download"
    local K0S_BIN_FILE="k0s-${K0S_VERSION}-amd64"
    local K0S_BIN_URL="${K0S_BIN_PREFIX_URL}/${K0S_VERSION}/${K0S_BIN_FILE}"

    if [[ ! -f "./build/$K0S_BIN_FILE" ]]; then
        wget -P ./build "$K0S_BIN_URL"
    fi
}

temp_ssh() {
    set +x
    local CONFIG=$(cat ./config.json)
    local SSH_IDENTITY=$(echo $CONFIG | jq -cr '.ssh.identity')
    set -x
    ssh \
        -o "IdentitiesOnly=yes" -i "$SSH_IDENTITY" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "StrictHostKeyChecking no" $@
}

temp_scp() {
    set +x
    local CONFIG=$(cat ./config.json)
    local SSH_IDENTITY=$(echo $CONFIG | jq -cr '.ssh.identity')
    set -x
    scp \
        -o "IdentitiesOnly=yes" -i "$SSH_IDENTITY" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "StrictHostKeyChecking no" $@
}

start_nodes
