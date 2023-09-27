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

setup_network() {
    sudo ip link add br0 type bridge
    sudo ip addr add 10.0.0.0/24 dev br0
    sudo ip link set up dev br0

    # Allows guests to reach internet
    sudo iptables -t nat -A POSTROUTING ! -o br0 --source 10.0.0.0/24 -j MASQUERADE

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_NAME=$(echo $NODE | jq -r '.name')

        sudo ip tuntap add "${NODE_NAME}tap" mode tap
        sudo ip link set "${NODE_NAME}tap" up
        sudo ip link set "${NODE_NAME}tap" master br0
    done
}

setup_gateway() {
    sudo dnsmasq --conf-file=./config/dnsmasq.conf --no-daemon --no-resolv --no-hosts &
    local DNSMASQ_PID="$!"
    echo "DNSMASQ_PID=$DNSMASQ_PID"
    echo "$DNSMASQ_PID" > ./build/dnsmasq.pid
}

cleanup_gateway() {
    if [[ -f ./build/dnsmasq.pid ]]; then
        set +e
        kill "$(cat ./build/dnsmasq.pid)"
        set -e
    fi
}

generate_k0sctl_config() {
    SSH_PORT=$(echo $CONFIG | jq -cr '.ssh.port')
    SSH_PUBKEY=$(eval echo $(echo $CONFIG | jq -cr '.ssh.pubkey'))

    cat ./config/k0sctl_head.yaml

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_IP=$(echo $NODE | jq -r '.ip')
        NODE_ROLE=$(echo $NODE | jq -r '.role')

        if [[ "$NODE_ROLE" == "controller" ]] || [[ "$NODE_ROLE" == "worker" ]]; then
            cat <<EOF
  - role: ${NODE_ROLE}
    installFlags:
    - --debug
    ssh:
      address: ${NODE_IP}
      user: root
      port: ${SSH_PORT}
      keyPath: ${SSH_PUBKEY}
EOF
        fi
    done

    cat ./config/k0sctl_tail.yaml
}

temp_ssh() {
    ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking no" $@
}

temp_scp() {
    scp -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking no" $@
}

download_k0s() {
    K0S_VERSION=$(echo $CONFIG | jq -cr '.k0s_version')
    K0S_BIN_PREFIX_URL="https://github.com/k0sproject/k0s/releases/download"
    K0S_BIN_FILE="k0s-v${K0S_VERSION}-amd64"
    K0S_BIN_URL="${K0S_BIN_PREFIX_URL}/v${K0S_VERSION}/${K0S_BIN_FILE}"

    if [[ ! -f "./build/$K0S_BIN_FILE" ]]; then
        wget -P ./build "$K0S_BIN_URL"
    fi
}

setup_nodes() {
    BASE_IMAGE=$(echo $CONFIG | jq -cr '.base_image')
    SSH_PORT=$(echo $CONFIG | jq -cr '.ssh.port')
    SSH_PUBKEY=$(eval echo $(echo $CONFIG | jq -cr '.ssh.pubkey'))

    if [[ ! -f "./build/$BASE_IMAGE" ]]; then
        wget -P build https://cloud.debian.org/images/cloud/bookworm/latest/$BASE_IMAGE
    fi

    SSH_KEY=$(cat $SSH_PUBKEY) envsubst < ./config/cloud_init.yaml \
        | tee \
        | cloud-localds -v ./build/seed.iso -

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_NAME=$(echo $NODE | jq -r '.name')
        NODE_MAC=$(echo $NODE | jq -r '.mac')
        NODE_DISK="./build/disk/${NODE_NAME}.qcow2"

        if [[ ! -f "$NODE_DISK" ]]; then
            mkdir -p "$(dirname $NODE_DISK)"
            cp "./build/$BASE_IMAGE" "$NODE_DISK"
            qemu-img resize "$NODE_DISK" 10G
        fi

        sudo qemu-system-x86_64 \
            -name "$NODE_NAME" \
            -m 2G \
            -smp 2 \
            -device "virtio-net-pci,netdev=${NODE_NAME}tap,mac=${NODE_MAC}" \
            -netdev "tap,id=${NODE_NAME}tap,ifname=${NODE_NAME}tap,script=no" \
            -drive "file=./${NODE_DISK},if=virtio,cache=writeback,discard=ignore,format=qcow2" \
            -drive "file=./build/seed.iso,media=cdrom" \
            -boot d \
            -machine type=pc,accel=kvm &
    done

    INSTALL_K0S=false

    # Wait for nodes to come online
    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_IP=$(echo $NODE | jq -r '.ip')
        NODE_ROLE=$(echo $NODE | jq -r '.role')

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

                K0S_VERSION=$(echo $CONFIG | jq -cr '.k0s_version')
                K0S_BIN_FILE="k0s-v${K0S_VERSION}-amd64"

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
        generate_k0sctl_config \
            | tee ./build/k0sctl.yaml \
            | k0sctl --debug apply --config -

        # Get and merge kubeconfig
        k0sctl kubeconfig --config ./build/k0sctl.yaml > ./build/kubeconfig
        KUBECONFIG="./build/kubeconfig" kubectl config view --flatten > ~/.kube/config

        set -e
    fi
}

cleanup_nodes() {
    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        NODE_DISK="./${NODE_NAME}.qcow2"

        if [[ -f "$NODE_DISK" ]]; then
            rm $NODE_DISK
        fi
    done
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

trap cleanup EXIT

cleanup() {
    cleanup_gateway
    cleanup_network
}

cleanup_network
setup_network
setup_gateway
setup_nodes

set +e

echo "Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml

wait_for 'ingress-nginx' \
    --namespace ingress-nginx \
    --for=condition=ready pod \
    -l app.kubernetes.io/component=controller \
    --timeout 300s

HTTP_NODE_PORT=$(kubectl get -n ingress-nginx svc ingress-nginx-controller -o=json \
    | jq -c '.spec.ports[] | select(.appProtocol == "http") | .nodePort')

HTTPS_NODE_PORT=$(kubectl get -n ingress-nginx svc ingress-nginx-controller -o=json \
    | jq -c '.spec.ports[] | select(.appProtocol == "https") | .nodePort')

HTTP_NODE_PORT=$HTTP_NODE_PORT HTTPS_NODE_PORT=$HTTPS_NODE_PORT envsubst \
    < ./config/haproxy.cfg | tee ./build/haproxy.cfg

for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
    NODE_IP=$(echo $NODE | jq -r '.ip')
    NODE_ROLE=$(echo $NODE | jq -r '.role')

    if [[ "$NODE_ROLE" == "lb" ]]; then
        temp_scp ./build/haproxy.cfg "root@$NODE_IP:/etc/haproxy/haproxy.cfg"
        temp_ssh "root@$NODE_IP" "systemctl restart haproxy"

        while true; do
            echo "$NODE_IP: Waiting for haproxy.service to start"
            sleep 5
            if temp_ssh "root@$NODE_IP" "systemctl is-active haproxy"; then
                break
            fi
        done
    fi
done

kubectl apply -f ./test.yaml

wait_for 'test pod' \
    --for=condition=ready pod \
    -l app.kubernetes.io/name=nginx \
    --timeout 300s

curl -ik -H 'Host: example.com' https://10.0.0.13

sleep infinity
