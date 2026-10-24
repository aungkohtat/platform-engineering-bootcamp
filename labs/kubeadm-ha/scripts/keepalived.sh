#!/usr/bin/env bash
# Control planes only: keepalived floats the VIP onto a control plane whose local
# HAProxy can reach a healthy kube-apiserver (course lesson 0002, plus HAProxy).
# Inputs: NODE_IP, VIP, PRIORITY, STATE, PEERS ("ip ip"), API_PORT (HAProxy's port).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -q keepalived

# The interface holding the LAN IP. Look it up rather than hardcoding enp0s8.
# No early `exit` in awk: it can SIGPIPE `ip` and fail the pipeline under pipefail.
IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '!f && $4 ~ "^"ip"/" {print $2; f=1}')
[[ -n "$IFACE" ]] || {
    echo "no interface has ${NODE_IP}" >&2
    exit 1
}

UNICAST_PEERS=""
for p in $PEERS; do
    UNICAST_PEERS+="        ${p}"$'\n'
done

# The check is run directly, not through a shell, so it must be a single command.
# -f makes HTTP errors fail; without it curl exits 0 on a 500.
#
# The check goes through the local HAProxy, so one dead apiserver does not move the VIP:
# HAProxy routes around it. The VIP moves when this node's HAProxy is down or has no
# healthy backend left.
#
# weight -20 instead of a hard fault: before kubeadm init every check fails, every
# priority drops by the same 20, and kyl-cp1 still wins the VIP, so init can reach it.
#
# Unicast VRRP: multicast over a Wi-Fi bridge is unreliable.
cat >/etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id $(hostname)
    enable_script_security
    script_user root
}

vrrp_script chk_apiserver {
    script "/usr/bin/curl -sfk --max-time 2 https://127.0.0.1:${API_PORT}/healthz"
    interval 2
    weight -20
    fall 2
    rise 2
}

vrrp_instance K8S_API {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1
    unicast_src_ip ${NODE_IP}
    unicast_peer {
${UNICAST_PEERS}    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_apiserver
    }
}
EOF
systemctl enable keepalived
systemctl restart keepalived
