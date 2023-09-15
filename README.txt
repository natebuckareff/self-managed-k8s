To bootstrap/start the cluster:

```
./start_cluster.sh
```

To reset the cluster without clearing the download cache:

```
rm -fr ./build/disk
```

To check that its actually working:

```
curl -ik -H 'Host: example.com' https://10.0.0.13
```

To access an an individual VM after bootstrapping (for debugging):

```
NODE_NAME=node0
sudo qemu-system-x86_64 \
    -name "$NODE_NAME" \
    -m 2G \
    -smp 2 \
    -device "virtio-net-pci,netdev=net0" \
    -netdev "user,id=net0,hostfwd=tcp::2222-:22" \
    -drive "file=./build/disk/${NODE_NAME}.qcow2,if=virtio,cache=writeback,discard=ignore,format=qcow2" \
    -drive "file=./build/seed.iso,media=cdrom" \
    -boot d \
    -serial stdio \
    -machine type=pc,accel=kvm
```
