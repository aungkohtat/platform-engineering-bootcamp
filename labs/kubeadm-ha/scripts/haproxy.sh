#!/usr/bin/env bash
# Control planes only: HAProxy spreads API traffic over every healthy kube-apiserver.
# keepalived floats the VIP onto one node's HAProxy; HAProxy on that node forwards
# to all three apiservers, dropping any that fail /readyz.
# Inputs: API_PORT (HAProxy's port, the controlPlaneEndpoint port), CP_IPS ("ip ip ip").
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -q haproxy

SERVERS=""
i=1
for ip in $CP_IPS; do
    SERVERS+="    server kyl-cp${i} ${ip}:6443"$'\n'
    i=$((i + 1))
done

# TCP passthrough: clients still see the apiserver's own certificate, whose SANs
# include kyl-vip. Long client/server timeouts so kubectl and kubelet watches are
# not cut every few seconds.
cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4000
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend k8s-api
    bind *:${API_PORT}
    default_backend k8s-api

# /readyz is readable anonymously, so the health check needs no credentials.
backend k8s-api
    balance roundrobin
    option httpchk
    http-check send meth GET uri /readyz
    http-check expect status 200
    default-server check check-ssl verify none inter 2s fall 2 rise 2
${SERVERS}
# Read-only stats on localhost: curl -s 'http://127.0.0.1:8404/stats;csv'
listen stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
EOF
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy
systemctl restart haproxy
