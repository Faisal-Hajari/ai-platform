# ai-platform
System for serving AI models over k8s

## Layout

- `infrastructure/k8s-ansible/` — the Ansible play that bootstraps the node: containerd,
  kubeadm, Cilium (as the CNI *and* the ingress controller, with kube-proxy skipped) and
  ArgoCD.
- [`infrastructure/k8s-ansible/system-apps/`](infrastructure/k8s-ansible/system-apps/README.md)
  — what ArgoCD needs in order to run, deployed by that play: the Cilium chart and its
  configuration, and ArgoCD's own ApplicationSet. Exactly two members, and that README
  states the rule for what may join them.
- [`deployment/`](deployment/README.md) — the charts and manifests ArgoCD syncs. The
  ApplicationSet picks them up from here. Empty today.
- `infrastructure/scripts/` — operational scripts, described below.

The split is the point: the ApplicationSet's generator path is `deployment/*/*`, so it
cannot reach `system-apps/` and needs no exclusion list. Cilium sat inside `deployment/`
until #38, which meant the generator's `prune`/`selfHeal` policy applied to the CNI —
a controller reconciling the network it runs on.

### Application names

The generated Applications are named `<namespace>-<chart>` — a directory
`deployment/ai-services/vllm` becomes the Application `ai-services-vllm`. The leaf
directory alone is not unique: it is only namespaced by the directory above it, so
`deployment/ingress/nginx` and `deployment/ai-services/nginx` would name the same
Application twice and each reconcile would overwrite the other's namespace and path.

Renaming is safe on a running cluster. The ApplicationSet deletes the Applications that
carry the old names, but the template sets no `resources-finalizer`, so that delete does
not cascade to the workloads; the new Applications sync the same paths and adopt the
resources that are already there.

## Bootstrap

On a fresh machine, one command:

```bash
./infrastructure/scripts/build_cluster.sh
```

It installs the two things that cannot be Ansible tasks — Ansible itself and its two
collections — checks what the play would otherwise discover hundreds of tasks in, runs the
play, and prints the finished cluster's end state. Everything else the node needs,
`crictl` included, is a task in the play.

`group_vars/k8s-master/vault.yml` is tracked here, so a clone already has the file; what
it cannot supply is the contents. It must hold `vault_become_pass` and
`vault_argocd_deploy_key`, and a vault missing either is reported by the play's own
`pre_tasks` within seconds, before the run touches the host.

The two commands it wraps, if you would rather run them by hand:

```bash
./infrastructure/scripts/install_ansible.sh
cd infrastructure/k8s-ansible
ansible-playbook -i inventory.ini playbook.yml --ask-vault-pass
```

`--ask-vault-pass` is not optional: `group_vars/k8s-master/vars.yml` takes
`ansible_become_pass` from the vault-encrypted `vault.yml` beside it, so the run cannot
load group_vars without the secret. `--vault-password-file` works too.

The play locates `system-apps/` relative to itself, via Ansible's `playbook_dir` — the
directory holding `playbook.yml`, which `system-apps/` sits beside. There is nothing to
pass and nothing to configure.

It used to read a `repo_path` variable that `group_vars/` defaulted to
`/home/{{ ansible_user }}/dev/ai-platform`. That was a *guess* about where the checkout
lives, and a wrong guess was silent: run the play from a second clone, `/opt`, or a git
worktree and it read `system-apps/` out of the guessed directory and deployed whatever was
on disk there rather than the tree you were looking at. No task compared the two.

Re-running the play is also the *only* update path for anything under `system-apps/`:
nothing reconciles behind it, and `helm upgrade --install` corrects drift on every run.

## Host-specific values

This cluster runs on one machine, and a few values describe *that* machine rather than
the platform. Moving to different hardware, a different NIC or a different LAN means
editing these — nothing discovers them at run time.

| Value | Declared in | Consumed by |
|---|---|---|
| API server address | [`system-apps/cilium/values.yaml`](infrastructure/k8s-ansible/system-apps/cilium/values.yaml) (`k8sServiceHost`) | Cilium's direct dial, **and** `kubeadm init --apiserver-advertise-address` — the playbook reads this key, so both are pinned to the one value |
| Pod CIDR | same file (`ipam.operator.clusterPoolIPv4PodCIDRList`) | Cilium's allocator **and** `kubeadm init --pod-network-cidr`, same way. Rebuild-only; see the comment there |
| Ingress address | same file (`lbipam.cilium.io/ips`) | the shared `cilium-ingress` LoadBalancer. Must sit inside the pool below |
| LoadBalancer pool | [`system-apps/cilium/config/ip-pool.yaml`](infrastructure/k8s-ansible/system-apps/cilium/config/ip-pool.yaml) | LB-IPAM. A free range on the LAN, outside the DHCP scope |
| NIC name (`eno1`) | [`system-apps/cilium/config/l2-policy.yaml`](infrastructure/k8s-ansible/system-apps/cilium/config/l2-policy.yaml) | L2 announcements — the interface that ARPs for pool addresses |
| Login user | [`infrastructure/k8s-ansible/inventory.ini`](infrastructure/k8s-ansible/inventory.ini) | Ansible, and the home the kubeconfig and the chart cache are written into |

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
| `check_deployments.sh` | Renders every chart in `system-apps/` and `deployment/` the way its deployer will and asserts the invariants that have bitten this cluster before. Run before pushing changes to either. |
| `recover_cilium.sh` | Unsticks a Cilium that is CrashLooping against the API server ClusterIP. Fix `k8sServiceHost` in `values.yaml` and re-run the playbook afterwards — the patches are a stopgap, and the playbook is now the only thing that renders Cilium. |
| `recover_apiserver.sh` | Clears a static pod wedged in `CreateContainerError` after a backward clock step. Needs root and `crictl`. |
| `nuke_cluster.sh` | Tears the cluster down far enough for the playbook to rebuild it, including the Cilium node-local state `kubeadm reset` leaves behind. Needs root and `crictl`. |
| `build_cluster.sh` | Builds the cluster from a fresh machine: installs Ansible and its collections, repairs a half-configured apt source if an earlier run left one, runs the playbook, then prints the finished cluster's end state. Run as the login user, not with `sudo`. |
| `destroy_cluster.sh` | Removes the cluster *and everything installed to run it* — packages, Helm, `crictl`, the apt repo, the host tuning — then asserts the machine is actually clean. `--keep-packages` stops at the `nuke_cluster.sh` line instead. Leaves Ansible, chrony and Docker alone. Run as the login user, not with `sudo`. |

### crictl

`nuke_cluster.sh`, `recover_apiserver.sh` and `destroy_cluster.sh` all need `crictl`, and
`kubeadm reset` drives the CRI through it — without it the reset reports success while
leaving containers running. It is not packaged on Ubuntu.

**The playbook installs it**, from a version and per-architecture SHA256 pinned in its
`vars:` block beside the Helm pin, and on the same reasoning: the checksum is what makes
the version mean anything, so bumping `crictl_version` means replacing both digests. Only
amd64 and arm64 are pinned; anything else fails the play's architecture assert rather than
installing something unverified.

That pin is the only copy. It was briefly stated three times — here, in `build_cluster.sh`
and in the play — with nothing keeping them in step; the script's bash reimplementation of
the play's own pinned-download block is gone, and this section no longer restates the
digests.
