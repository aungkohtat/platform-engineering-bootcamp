#!/usr/bin/env bash
# kyl-cp1 only: write the kubeadm config used once by `kubeadm init`.
# Generated here so the IPs and version come from the Vagrantfile alone.
# Inputs: NODE_IP, VIP_NAME, K8S_VERSION, API_PORT (HAProxy's port on the VIP).
set -euo pipefail

cat >/home/vagrant/kubeadm-config.yaml <<EOF
# sudo kubeadm init --config kubeadm-config.yaml --upload-certs
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  # LAN IP, not the VirtualBox NAT address (10.0.2.15) that owns the default route.
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
# Cilium replaces kube-proxy (lesson 0003).
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
# HAProxy on the VIP, not an apiserver: every client is spread over all three.
controlPlaneEndpoint: "${VIP_NAME}:${API_PORT}"
networking:
  # Must not overlap VirtualBox NAT (10.0.2.0/24) or the LAN.
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
chown vagrant: /home/vagrant/kubeadm-config.yaml
