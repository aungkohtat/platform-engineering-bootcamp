# PE Bootcamp Phase 1 lab (VirtualBox + Vagrant)

The course's Phase 1 cluster, built on one 32 GB Mac (`mbp`). It has 3 control planes
and 3 workers bridged onto the home LAN. keepalived floats one VIP onto a control
plane, and HAProxy there spreads API requests over all three apiservers. Cilium runs
with no kube-proxy and announces LoadBalancer IPs on the LAN. Envoy Gateway serves as
ingress on top.

```
            Home LAN 192.168.1.0/24 (bridged)        mbp = admin workstation
                              │
                 kyl-vip 192.168.1.10:8443   ← keepalived, health-checks the local HAProxy
                              │
              HAProxy :8443 on each control plane  ← /readyz checks, round robin
                    ┌─────────┼─────────┐
        kyl-cp1 .11:6443  kyl-cp2 .12:6443  kyl-cp3 .13:6443  apiserver + stacked etcd
        kyl-w1  .14        kyl-w2  .15        kyl-w3  .16     Cilium (no kube-proxy)
                              │
         LoadBalancer IPs .200–.207 ← Cilium L2 announcement ← Envoy Gateway
```

| Pinned | Version |
|---|---|
| Ubuntu | 26.04 (`bento/ubuntu-26.04`) |
| Kubernetes | 1.36.5. Cilium 1.20 and Envoy Gateway v1.9 both test up to 1.36 |
| containerd | 2.x from Docker's apt repo |
| Cilium | 1.20.3, the course's pin |
| Envoy Gateway | v1.9.2 |

**How this lab differs from the course:**
- **Sizing.** Control planes are 2 vCPU / 3 GB and workers 2 vCPU / 4 GB, about 21 GB in
  total. The course suggests 4 GB control planes and 8 GB workers, which needs 36 GB.
- **Interfaces.** Each VM also has a VirtualBox NAT adapter for internet access. So
  kubelet, kubeadm and Cilium are pinned to the LAN IP.
- **HAProxy (not in the course).** The course points keepalived's VIP straight at
  `:6443`, so one apiserver takes all traffic. Here the VIP lands on HAProxy at `:8443`,
  which spreads requests over all three and drops an apiserver that fails `/readyz`.
  **Wherever the course says `kyl-vip:6443` or `k8sServicePort=6443`, use `8443`.**
  The keepalived-only build is kept as the `keepalived-only` snapshot.
- **keepalived** uses unicast VRRP with no password. Its check is a single `curl -f` to
  the local HAProxy, because keepalived doesn't run it through a shell. One dead
  apiserver no longer moves the VIP; HAProxy routes around it.

## 0. Before you start (on `mbp`)

1. **Check the addresses are free.** `192.168.1.10–16` and `192.168.1.200–207` must
   sit outside your router's DHCP pool. Check the router's admin page, or
   `ping -c1 192.168.1.10` (no reply is good). If they clash, change `LAN` or the last
   octets in the `Vagrantfile`, plus the IPs in `manifests/cilium-*.yaml`.
2. **Stop the Mac sleeping** while plugged in:
   `sudo pmset -c sleep 0 disksleep 0 powernap 0`.
3. **Turn Cloudflare WARP off.** It takes over routing and DNS.
4. **Install the tools:**
   `brew install --cask virtualbox vagrant && brew install cilium-cli jq`. Then approve
   Oracle under **System Settings → Privacy & Security** and restart. `kubectl` and
   `helm` are already installed.
5. **Check the network adapter name:** `VBoxManage list bridgedifs | grep ^Name`. The
   Vagrantfile tries `en0: Wi-Fi`. If yours differs, run with
   `BRIDGE="<exact name>" vagrant up`.
6. **Optional: graph every VM in Beszel.** With the Beszel hub running on `mbp`, create a
   universal token under **Settings → Tokens**, then export these before `vagrant up`
   (or put them in the repo's gitignored `.envrc.local`). Each node's agent dials the
   hub and registers itself under its hostname:
   ```bash
   export BESZEL_KEY="$(ssh-keygen -y -f ~/.local/beszel/beszel_data/id_ed25519)"
   export BESZEL_TOKEN="<universal token>"
   export BESZEL_HUB_URL="http://192.168.1.120:8090"
   ```
   Agents dial the hub, not the other way round: macOS Local Network privacy blocks an
   unsigned hub running as a background service from opening LAN connections.

> **Wi-Fi vs Ethernet.** Bridging over Wi-Fi works, but VirtualBox has to rewrite MAC
> addresses to do it. If the VIP or a LoadBalancer IP answers on `mbp` but not from
> another device on the LAN, plug in a USB/Thunderbolt Ethernet adapter and bridge
> to that instead.

## Lesson 0001: Hosts and the container runtime

```bash
cd ~/labs/kubeadm-ha
vagrant up            # 6 VMs, 10–15 min
```

Every node gets swap off, `overlay` and `br_netfilter`, sysctls, and containerd 2.x
with the systemd cgroup driver, held like the course's step 8 (the package is
`containerd.io` from Docker's repo). It also gets pinned kubelet, kubeadm and kubectl, and
`--node-ip` set to its LAN IP. The control planes also get keepalived.

**Check your win:**
```bash
for n in kyl-cp1 kyl-cp2 kyl-cp3 kyl-w1 kyl-w2 kyl-w3; do
  vagrant ssh $n -c "sudo crictl info >/dev/null && echo $n ok"
done
ping -c1 192.168.1.10      # VIP already answers: kyl-cp1 holds it before init
```

## Lesson 0002: The HA control plane with kubeadm

**First control plane:**
```bash
vagrant ssh kyl-cp1
sudo kubeadm init --config kubeadm-config.yaml --upload-certs | tee init.out
exit
```

The generated `kubeadm-config.yaml` sets these options:
- `controlPlaneEndpoint: kyl-vip:8443` (HAProxy)
- `advertiseAddress: 192.168.1.11`
- `apiServer.certSANs: [192.168.1.10]`. kubeadm only adds the endpoint's name, and
  Cilium reaches the API by the VIP's IP.
- `skipPhases: [addon/kube-proxy]`

`init.out` holds two join commands, and the `--certificate-key` expires after 2 hours.

**kubectl through the VIP.** Run these on `mbp`:
```bash
grep -q kyl-vip /etc/hosts || echo "192.168.1.10 kyl-vip" | sudo tee -a /etc/hosts
umask 077                  # it holds cluster-admin credentials
# Write to a temp file first: if the login fails, `> kubeconfig` would leave it empty.
vagrant ssh kyl-cp1 -c "sudo cat /etc/kubernetes/admin.conf" > kubeconfig.new \
  && grep -q client-key-data kubeconfig.new && mv kubeconfig.new kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes          # kyl-cp1 NotReady: expected, no CNI yet
```

> **Over a Wi-Fi bridge, `mbp` itself cannot reach the VIP**, and can lose ARP for
> individual VMs too. Other LAN devices are fine. VirtualBox's Wi-Fi bridging rewrites MAC
> addresses, so from the host an address can stay `(incomplete)` in `arp -n` and kubectl
> times out. Run kubectl from another LAN machine with the same `kubeconfig` and
> `/etc/hosts` line, or bridge to Ethernet instead. On `mbp`, point the kubeconfig
> straight at a control plane it can still reach. Every apiserver cert lists its own IP:
> ```bash
> arp -n 192.168.1.12                                        # a MAC, not (incomplete)
> kubectl config set-cluster kubernetes --server https://192.168.1.12:6443
> ```
> **If kubectl tries `localhost:8080`, the kubeconfig is empty or missing.** Fetch it
> again with the commands above.

**Join kyl-cp2 and kyl-cp3.** Use the `--control-plane` command from `init.out`,
adding each node's own LAN IP:
```bash
vagrant ssh kyl-cp2 -c "sudo kubeadm join kyl-vip:8443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <key> \
  --apiserver-advertise-address 192.168.1.12"
```
Use `192.168.1.13` on kyl-cp3. **Don't drop `--apiserver-advertise-address`.** Without
it, kubeadm uses the NAT interface (10.0.2.15, the same on every VM), and the etcd
members can't reach each other.

**Join the workers** with the plain join command:
```bash
for w in kyl-w1 kyl-w2 kyl-w3; do
  vagrant ssh $w -c "sudo kubeadm join kyl-vip:8443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
done
```

If more than 2 hours have passed, or `init.out` is lost, generate fresh credentials on
kyl-cp1. Pass `--config`: without it, `upload-certs` can time out bootstrapping the
admin user.
```bash
sudo kubeadm init phase upload-certs --upload-certs --config kubeadm-config.yaml
sudo kubeadm token create --print-join-command
```

**Never re-run `kubeadm init` to get the join commands back.** On an initialised node
it fails its preflight checks, and `| tee init.out` overwrites the file with the
failure. Check `kubectl get nodes` first.

**Check your win:**
```bash
kubectl get nodes -o wide        # 6 nodes, all NotReady, INTERNAL-IP all 192.168.1.x
kubectl -n kube-system exec etcd-kyl-cp1 -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  member list -w table           # 3 members, all started
kubectl get --raw /healthz       # ok
kubectl -n kube-system get ds kube-proxy   # NotFound: correct

# HAProxy on the VIP holder sees all three apiservers as UP
vagrant ssh kyl-cp1 -c "curl -s 'http://127.0.0.1:8404/stats;csv' | cut -d, -f1,2,18 | grep k8s-api"
```

## Lesson 0003: Cilium, the kube-proxy-free CNI

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium --version 1.20.3 -n kube-system -f manifests/cilium-values.yaml
cilium status --wait
```

Key values in `manifests/cilium-values.yaml`:
- `kubeProxyReplacement: true`
- `k8sServiceHost: 192.168.1.10` (the VIP). It must be an IP, because the agent starts
  before CoreDNS. If the operator crash-loops with `x509: certificate is valid for …
  not 192.168.1.10`, the apiserver certs lack that SAN: see `certSANs` in Lesson 0002.
- `ipam.mode: kubernetes`. Cilium's default pod range overlaps the NAT network.
- `l2announcements` on, ready for the next lesson.

**Check your win:**
```bash
cilium status                                  # KubeProxyReplacement: True, all OK
kubectl get nodes                              # all 6 Ready
kubectl -n kube-system rollout restart deploy coredns   # if CoreDNS stayed Pending
cilium connectivity test                       # several minutes; all green
cilium connectivity test --cleanup
```

## Lesson 0004: The LAN-facing load balancer

The course hasn't written this lesson yet. This section follows the Phase 1 overview
and Cilium's L2 announcement docs.

```bash
kubectl apply -f manifests/cilium-lb.yaml      # pool .200–.207 + L2 policy on workers
kubectl create deployment hello --image=traefik/whoami:v1.11.0
kubectl expose deployment hello --port 80 --type LoadBalancer
kubectl get svc hello                          # EXTERNAL-IP 192.168.1.200
```

**Check your win.** `curl` the IP from another device on the LAN, e.g. the MacBook Air,
not just from `mbp`:
```bash
curl http://192.168.1.200/
kubectl get leases -n kube-system | grep l2announce   # which worker answers ARP
kubectl delete svc,deploy hello
```

## Ingress: Envoy Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
  -n envoy-gateway-system --create-namespace
kubectl wait -n envoy-gateway-system deploy/envoy-gateway --for=condition=Available --timeout=5m

kubectl apply -f manifests/envoy-gateway.yaml     # GatewayClass + Gateway "eg"
kubectl wait -n envoy-gateway-system gateway/eg --for=condition=Programmed --timeout=5m
kubectl apply -f manifests/demo-app.yaml          # whoami + HTTPRoute for whoami.lab.local

GW_IP=$(kubectl get gateway -n envoy-gateway-system eg -o jsonpath='{.status.addresses[0].value}')
curl -H "Host: whoami.lab.local" http://$GW_IP/   # Hostname: rotates across 3 pods
```

The Envoy Service takes the next IP from the Cilium pool. To browse by name, add
`<GW_IP> whoami.lab.local` to `/etc/hosts` on any LAN machine.

## Lesson 0006 preview: lose a control plane

```bash
vagrant halt kyl-cp1
kubectl get nodes                     # still answers: VIP moved, etcd 2/3 quorum
vagrant ssh kyl-cp2 -c "ip -br -4 a | grep 192.168.1.10"
vagrant up kyl-cp1                    # VIP moves back once its apiserver is healthy
```

## Tear down

```bash
vagrant destroy -f && rm -f kubeconfig
```
