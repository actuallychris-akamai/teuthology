#!/usr/bin/bash
set -x
# Clean up Ceph state from previous runs
rm -rf /var/lib/ceph/*
rm -rf /etc/ceph/*
rm -rf /home/ubuntu/cephtest

hostname="${TESTNODE_NAME:-$(hostname)}"
payload="{\"name\": \"$hostname\", \"machine_type\": \"testnode\", \"up\": false}"
for i in $(seq 1 5); do
    echo "attempt $i"
    curl -s -f -X PUT -d "$payload" http://paddles:8080/nodes/$hostname/ && break
    sleep 1
done
