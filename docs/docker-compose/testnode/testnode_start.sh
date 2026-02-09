#!/usr/bin/bash
set -x
# Import container environment variables (systemd services don't inherit them)
while IFS='=' read -r -d '' key val; do
    case "$key" in
        SSH_PUBKEY|TESTNODE_NAME|CEPH_VOLUME_ALLOW_LOOP_DEVICES)
            export "$key=$val"
            ;;
    esac
done < /proc/1/environ
echo "$SSH_PUBKEY" > /root/.ssh/authorized_keys
echo "$SSH_PUBKEY" > /home/ubuntu/.ssh/authorized_keys
chown ubuntu /home/ubuntu/.ssh/authorized_keys
mkdir -p /run/sshd
# Wait for sshd to be ready before registering with paddles
for i in $(seq 1 30); do
    cat /proc/net/tcp 2>/dev/null | grep -q ':0016 ' && break
    sleep 1
done
. /etc/os-release
if [ $ID = 'centos' ]; then
    VERSION_ID=${VERSION_ID}.stream
fi
NODENAME="${TESTNODE_NAME:-$(hostname)}"
create_payload="{\"name\": \"${NODENAME}\", \"machine_type\": \"testnode\", \"up\": true, \"locked\": false, \"os_type\": \"${ID}\", \"os_version\": \"${VERSION_ID}\"}"
update_payload="{\"name\": \"${NODENAME}\", \"machine_type\": \"testnode\", \"up\": true}"
for i in $(seq 1 5); do
    echo "attempt $i"
    # Try POST (create) first, fall back to PUT (update) if node already exists
    curl -s -f -d "$create_payload" http://paddles:8080/nodes/ && break
    curl -s -f -X PUT -d "$update_payload" http://paddles:8080/nodes/${NODENAME}/ && break
    sleep 1
done
