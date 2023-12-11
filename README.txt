Dependencies:
- jq
- kubectl
- k0sctl (https://github.com/k0sproject/k0sctl#installation)

1. Setup networking:

```
./setup_network.sh
```

2. Start QEMU VMs and install K0S/HAProxy:

```
./start_nodes.sh
```

3. Install nginx ingress controller and apply test.yaml:

```
./setup_k8s.sh
```

`start_nodes.sh` merges the K0S kubeconfig into your local kubeconfig, so at
this point you can monitor progress with `kubectl get pods -A --watch` or
something like `k9s`.

4. Verify that test pod is working:

```
curl -ik -H 'Host: example.com' https://10.0.0.13
```

Reset nodes by deleting their disks:

```
./reset_nodes.sh
```

Cleanup networking:

```
./cleanup_network.sh
```
