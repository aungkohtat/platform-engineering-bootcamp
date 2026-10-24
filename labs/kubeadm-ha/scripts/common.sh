#!/usr/bin/env bash
# Every node: kernel prereqs, containerd 2.x, kubeadm/kubelet/kubectl, node-ip pinning.
# Inputs (from the Vagrantfile): NODE_IP, K8S_VERSION, HOSTS.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

K8S_MINOR="v${K8S_VERSION%.*}"

# Name resolution between nodes, kept in a marked block so re-provisioning is idempotent.
sed -i '/# BEGIN k8s-ha/,/# END k8s-ha/d' /etc/hosts
printf '# BEGIN k8s-ha\n%s\n# END k8s-ha\n' "$HOSTS" >>/etc/hosts

# kubelet refuses to start with swap on by default.
swapoff -a
sed -i '/\sswap\s/ s/^#*/#/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

apt-get update -q
apt-get install -y -q apt-transport-https ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings

# containerd 2.x from Docker's repo: Ubuntu 24.04's own package is the 1.7 series.
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
# shellcheck source=/dev/null
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
    gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list

apt-get update -q
apt-get install -y -q containerd.io

# containerd.io ships with the CRI plugin disabled; regenerate the full default config
# and switch runc to the systemd cgroup driver to match the kubelet.
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || {
    echo "SystemdCgroup not set in containerd config" >&2
    exit 1
}
systemctl restart containerd
systemctl enable containerd

# Pin the exact patch so kubeadm, kubelet and the control plane images all agree.
# No early `exit` in awk: it would SIGPIPE apt-cache and fail the pipeline under pipefail.
PKG_VERSION=$(apt-cache madison kubeadm | awk -v v="$K8S_VERSION" '!f && $3 ~ "^"v"-" {print $3; f=1}')
[[ -n "$PKG_VERSION" ]] || {
    echo "kubeadm ${K8S_VERSION} not found in ${K8S_MINOR} repo" >&2
    exit 1
}
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
apt-get install -y -q --allow-downgrades \
    "kubelet=${PKG_VERSION}" "kubeadm=${PKG_VERSION}" "kubectl=${PKG_VERSION}"
apt-mark hold kubelet kubeadm kubectl
# kubeadm no longer depends on cri-tools, so crictl has to be asked for by name.
apt-get install -y -q cri-tools

# VirtualBox gives every VM the same NAT address (10.0.2.15) on the first NIC.
# Without this the kubelet registers that address and pod traffic between nodes breaks.
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" >/etc/default/kubelet
systemctl enable kubelet

cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF
