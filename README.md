# ai-platform
System for serving AI models over k8s

## Layout

- `infrastructure/k8s-ansible/` — the Ansible play that bootstraps the node: containerd,
  kubeadm, Cilium (as the CNI *and* the ingress controller, with kube-proxy skipped) and
  ArgoCD.
- `deployment/` — the charts and manifests ArgoCD syncs. The ApplicationSet in
  `infrastructure/k8s-ansible/argocd/applicationset.yaml` picks them up from here.
- `infrastructure/scripts/` — operational scripts, described below.

### Application names

The generated Applications are named `<namespace>-<chart>` — the directory
`deployment/kube-system/cilium` becomes the Application `kube-system-cilium`. The leaf
directory alone is not unique: it is only namespaced by the directory above it, so
`deployment/ingress/nginx` and `deployment/ai-services/nginx` would name the same
Application twice and each reconcile would overwrite the other's namespace and path.

Renaming is safe on a running cluster. The ApplicationSet deletes the Applications that
carry the old names, but the template sets no `resources-finalizer`, so that delete does
not cascade to the workloads; the new Applications sync the same paths and adopt the
resources that are already there.

## Bootstrap

```bash
./infrastructure/scripts/install_ansible.sh
cd infrastructure/k8s-ansible
ansible-playbook -i inventory.ini playbook.yml --ask-vault-pass
```

`--ask-vault-pass` is not optional: `group_vars/k8s-master/vars.yml` takes
`ansible_become_pass` from the vault-encrypted `vault.yml` beside it, so the run cannot
load group_vars without the secret. `--vault-password-file` works too.

`repo_path` is the repository root, which the play reads Cilium's values and the
ApplicationSet from. It already defaults to `/home/{{ ansible_user }}/dev/ai-platform` in
`group_vars/k8s-master/vars.yml`; pass `-e repo_path=...` only if the checkout lives
somewhere else.

## Host-specific values

This cluster runs on one machine, and a few values describe *that* machine rather than
the platform. Moving to different hardware, a different NIC or a different LAN means
editing these — nothing discovers them at run time.

| Value | Declared in | Consumed by |
|---|---|---|
| API server address | [`deployment/kube-system/cilium/values.yaml`](deployment/kube-system/cilium/values.yaml) (`k8sServiceHost`) | Cilium's direct dial, **and** `kubeadm init --apiserver-advertise-address` — the playbook reads this key, so both are pinned to the one value |
| Pod CIDR | same file (`ipam.operator.clusterPoolIPv4PodCIDRList`) | Cilium's allocator **and** `kubeadm init --pod-network-cidr`, same way. Rebuild-only; see the comment there |
| Ingress address | same file (`lbipam.cilium.io/ips`) | the shared `cilium-ingress` LoadBalancer. Must sit inside the pool below |
| LoadBalancer pool | [`deployment/kube-system/cilium-config/ip-pool.yaml`](deployment/kube-system/cilium-config/ip-pool.yaml) | LB-IPAM. A free range on the LAN, outside the DHCP scope |
| NIC name (`eno1`) | [`deployment/kube-system/cilium-config/l2-policy.yaml`](deployment/kube-system/cilium-config/l2-policy.yaml) | L2 announcements — the interface that ARPs for pool addresses |
| Login user | [`infrastructure/k8s-ansible/inventory.ini`](infrastructure/k8s-ansible/inventory.ini) | Ansible; `repo_path` in `group_vars/` is derived from it |

The API server address and the pod CIDR used to be written twice each — once for Cilium
and once for kubeadm — and agreed only because nobody had changed one of them. They are
now single-sourced, and the playbook asserts, before it runs `kubeadm init`, that the
declared API server address is actually on the host **and** — once a cluster exists — that
it is still the address that cluster was built to advertise. The second one fires on a
re-run that looks like it should be a no-op, which is exactly when it is least expected
and most needed: see the paragraph below for why editing this value on a live cluster is
only half a fix.

**Give the node a DHCP reservation.** Its address is currently an ordinary lease
(`ip route show default` → `proto dhcp`), and a moved lease is expensive here. Because
there is no kube-proxy, Cilium reaches the API server by address and cannot fall back to
the `10.96.0.1` ClusterIP — that half is recoverable with
[`infrastructure/scripts/recover_cilium.sh`](infrastructure/scripts/recover_cilium.sh).
The API server's own advertise address and serving-cert SANs are fixed at `kubeadm init`,
so that half needs the certs regenerated or the cluster rebuilt. The assert turns a moved
lease into a clear failure at the top of the run instead of a deadlock partway through,
but a reservation avoids the situation.

## Scripts

Each script carries a shebang and is executable, so run it directly.

| Script | What it does |
| --- | --- |
| `install_ansible.sh` | Installs Ansible from the PPA on the control node. |
| `install_ssh.sh` | Installs and enables `sshd`. |
| `check_deployments.sh` | Renders every chart under `deployment/` the way ArgoCD will and asserts the invariants that have bitten this cluster before. Run before pushing changes to `deployment/`. |
| `recover_cilium.sh` | Unsticks a Cilium that is CrashLooping against the API server ClusterIP. Push the `k8sServiceHost` fix to `values.yaml` first — ArgoCD self-heals these patches away. |
| `recover_apiserver.sh` | Clears a static pod wedged in `CreateContainerError` after a backward clock step. Needs root and `crictl`. |
| `nuke_cluster.sh` | Tears the cluster down far enough for the playbook to rebuild it, including the Cilium node-local state `kubeadm reset` leaves behind. Needs root and `crictl`. |

### crictl

`nuke_cluster.sh` and `recover_apiserver.sh` need `crictl`, and `kubeadm reset` drives the
CRI through it — without it the reset reports success while leaving containers running.
It is not packaged on Ubuntu; install it from cri-tools.

Pinned to a version and to the SHA256 of the release artefact itself, on the same
reasoning as the Cilium CLI and Helm pins in `playbook.yml`: the checksum is what makes
the version mean anything, and it is per version and per architecture, so bumping
`VERSION` means replacing both digests. Only amd64 and arm64 are pinned — on anything
else `ARCH` stays unset, the download 404s, and the chain stops before `sudo tar`.

```bash
VERSION=v1.31.1
case "$(uname -m)" in
  x86_64)  ARCH=amd64  SHA256=0a03ba6b1e4c253d63627f8d210b2ea07675a8712587e697657b236d06d7d231 ;;
  aarch64) ARCH=arm64  SHA256=cd70f9b2f75c9619f40450d4b6e2c74aaab619917da517eff6787b442f8b0e56 ;;
esac

curl -fsSL -o crictl.tar.gz "https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-$ARCH.tar.gz" &&
  echo "$SHA256  crictl.tar.gz" | sha256sum -c - &&
  sudo tar zxf crictl.tar.gz -C /usr/local/bin crictl
rm -f crictl.tar.gz
```
