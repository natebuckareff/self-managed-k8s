#!/usr/bin/env bash

set -euxo pipefail

setup_k8s() {
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml

    wait_for 'ingress-nginx' \
        --namespace ingress-nginx \
        --for=condition=ready pod \
        -l app.kubernetes.io/component=controller \
        --timeout 300s

    set +x
    local HTTP_NODE_PORT=$(kubectl get -n ingress-nginx svc ingress-nginx-controller -o=json \
        | jq -c '.spec.ports[] | select(.appProtocol == "http") | .nodePort')

    local HTTPS_NODE_PORT=$(kubectl get -n ingress-nginx svc ingress-nginx-controller -o=json \
        | jq -c '.spec.ports[] | select(.appProtocol == "https") | .nodePort')

    local CONFIG=$(cat ./config.json)
    set -x

    HTTP_NODE_PORT=$HTTP_NODE_PORT HTTPS_NODE_PORT=$HTTPS_NODE_PORT \
        envsubst < ./config/haproxy.cfg \
            | tee ./build/haproxy.cfg

    for NODE in $(echo $CONFIG | jq -c '.nodes | .[]'); do
        set +x
        local NODE_IP=$(echo $NODE | jq -r '.ip')
        local NODE_ROLE=$(echo $NODE | jq -r '.role')
        set -x

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
        -l app.kubernetes.io/name=whoami \
        --timeout 300s

    sleep 5

    set +x
    echo "======================== TESTING ========================"
    echo "$ curl -ik -H 'Host: example.com' https://10.0.0.13"
    echo
    curl -ik -H 'Host: example.com' https://10.0.0.13
    echo "========================================================="
    set -x
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

setup_k8s
