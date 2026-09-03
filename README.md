# ai-platform
System for serving AI models over k8s

## Layout

- `infrastructure/k8s-ansible/` — the Ansible play that bootstraps the node: containerd,
  kubeadm, chrony, Helm, `crictl`, Cilium (as the CNI *and* the ingress controller, with
  kube-proxy skipped), NVIDIA's GPU Operator, and ArgoCD.
- [`infrastructure/k8s-ansible/system-apps/`](infrastructure/k8s-ansible/system-apps/README.md)
  — what ArgoCD cannot safely reconcile, deployed by that play: the Cilium chart and its
  configuration, NVIDIA's GPU Operator, and ArgoCD's own ApplicationSet. Three members,
  and that README states the two-clause rule for what may join them.
- [`deployment/`](deployment/README.md) — the charts and manifests ArgoCD syncs. The
  ApplicationSet picks them up from here. Empty today.
- `infrastructure/scripts/` — operational scripts, described below.
- `.github/workflows/check-deployments.yml` — runs `check_deployments.sh` on every pull
  request and every push to `main` that touches either half. See [CI](#ci).

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
collections — checks what the play would otherwise discover hundreds of tasks in, renders
both halves through `check_deployments.sh`, runs the play, and prints the finished
cluster's end state. Everything else the node needs, `crictl` included, is a task in the
play.

What the preflight decides before anything is installed: that you are not root, that
`sudo` works on a terminal, that `/usr/bin/sudo` is not sudo-rs, that `inventory.ini`'s
`ansible_user` is the user running the script, and that the vault exists and is encrypted.
The sudo-rs one is the least guessable: Ansible's become plugin drives `sudo` with flags
sudo-rs does not implement, and because the play is `become: true` at play level the
failure lands on *Gathering Facts* as a bare `sudo: invalid option`. No assert inside the
play could report it, which is why the check lives out here.

Options, all of which have defaults that suit the common case:

| Flag | Effect |
| --- | --- |
| `--vault-password-file FILE` | Read the vault password from `FILE` instead of prompting. Needed where there is no TTY. |
| `--skip-render-check` | Skip `check_deployments.sh`. It needs Helm, which the play installs, so a genuinely fresh machine skips it automatically. |
| `-- <args>` | Everything after `--` goes to `ansible-playbook`, e.g. `-- -vvv`. (`--check` is not usable against this play: most of it is `command`/`shell`, and check mode skips the tasks later ones read the results of.) |

`group_vars/k8s-master/vault.yml` is tracked here, so a clone already has the file; what
it cannot supply is the contents. It must hold `vault_become_pass` and
`vault_argocd_deploy_key`, and a vault missing either is reported by the play's own
`pre_tasks` within seconds, before the run touches the host.

If you would rather run it by hand, it is three steps rather than two —
`install_ansible.sh` installs the `ansible` PPA package and *nothing else*, so the
collections are a separate command:

```bash
./infrastructure/scripts/install_ansible.sh
ansible-galaxy collection install ansible.posix community.general
cd infrastructure/k8s-ansible
ansible-playbook -i inventory.ini playbook.yml --ask-vault-pass
```

Do not skip the middle line. The play uses `ansible.posix.sysctl` and
`community.general.modprobe`; the `ansible` package carries both and `ansible-core` alone
does not, so on an `ansible-core` machine the run dies with `couldn't resolve
module/action` — *after* swap is off and `/etc/fstab` has been rewritten.
`build_cluster.sh` asks `ansible-doc` whether each module resolves and installs only what
is missing, which is why the wrapped path needs no equivalent warning.

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
| Ingress address | same file (`lbipam.cilium.io/ips`) | the shared `cilium-ingress` LoadBalancer. Held by a pool reserved for that Service, and kept out of the general one |
| LoadBalancer pools | [`system-apps/cilium/config/ip-pool.yaml`](infrastructure/k8s-ansible/system-apps/cilium/config/ip-pool.yaml) | LB-IPAM. A free range on the LAN, outside the DHCP scope — and on the subnet the NIC below is attached to. Split into the one address the ingress reserves and the general range everything else is allocated from |
| NIC name (`eno1`) | [`system-apps/cilium/config/l2-policy.yaml`](infrastructure/k8s-ansible/system-apps/cilium/config/l2-policy.yaml) | L2 announcements — the interface that ARPs for pool addresses. Its subnet is the one the pool has to sit on, and that subnet is a lease on the node, so no file here states it |
| Login user | [`infrastructure/k8s-ansible/inventory.ini`](infrastructure/k8s-ansible/inventory.ini) | Ansible, and the home the kubeconfig and the chart cache are written into |

The API server address and the pod CIDR used to be written twice each — once for Cilium
and once for kubeadm — and agreed only because nobody had changed one of them. They are
now single-sourced, and the playbook asserts, before it runs `kubeadm init`, that the
declared API server address is actually on the host **and** — once a cluster exists — that
it is still the address that cluster was built to advertise. The second one fires on a
re-run that looks like it should be a no-op, which is exactly when it is least expected
and most needed: see the paragraph below for why editing this value on a live cluster is
only half a fix.

The pool and the NIC are a pair in the same way, and a harder one to see, because nothing
in the cluster reports it. LB-IPAM hands out pool addresses whatever the L2 policy says,
so a pool on a subnet that NIC is not attached to — or a policy naming a NIC this host
does not have, which applies without error — leaves every Ingress holding an
`EXTERNAL-IP` that answers no ARP. Only the two files are in git; the subnet is not. So
the check is split to match: `check_deployments.sh` asserts a policy exists and announces
LoadBalancer addresses, and the playbook resolves the interfaces that policy matches on
this host and refuses to build anything if the pool is off their subnets.

**Give the node a DHCP reservation.** Its address is currently an ordinary lease
(`ip route show default` → `proto dhcp`), and a moved lease is expensive here. Because
there is no kube-proxy, Cilium reaches the API server by address and cannot fall back to
the `10.96.0.1` ClusterIP — that half is recoverable with
[`infrastructure/scripts/recover_cilium.sh`](infrastructure/scripts/recover_cilium.sh).
The API server's own advertise address and serving-cert SANs are fixed at `kubeadm init`,
so that half needs the certs regenerated or the cluster rebuilt. The assert turns a moved
lease into a clear failure at the top of the run instead of a deadlock partway through,
but a reservation avoids the situation.

## GPUs

Serving models on a GPU is what this platform is for, and making one *schedulable* takes
four things. NVIDIA's GPU Operator provides three of them; the fourth is the host's.

| Piece | Owner |
|---|---|
| The driver | **the host.** Not installed here. The play asserts `nvidia-smi -L` lists a card, at the top of the run, and refuses to go on without one |
| `nvidia-container-toolkit` | the Operator's toolkit DaemonSet, into `/usr/local/nvidia` |
| containerd's `nvidia` runtime handler + the `RuntimeClass` | the same DaemonSet, as a containerd drop-in |
| The device plugin, which publishes `nvidia.com/gpu` | the Operator |

The Operator is deployed by the **playbook**, from
[`system-apps/gpu-operator/`](infrastructure/k8s-ansible/system-apps/README.md), not by
ArgoCD. That is what its README's second membership clause exists for: the toolkit
DaemonSet rewrites `/etc/containerd` and restarts containerd, and putting that under the
ApplicationSet would mean `prune` and `selfHeal` on the container runtime the reconciler
itself runs on — the same objection that moved the CNI out of `deployment/`, one layer
down.

The play does not configure containerd for GPUs anywhere. One writer, the way Cilium has
one renderer.

**What a GPU workload needs is just the resource limit:**

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

No `runtimeClassName`, and no change to how anything else on the node runs. The Operator
leaves `default_runtime_name = "runc"`, so non-GPU pods are untouched; the device plugin
runs with `DEVICE_LIST_STRATEGY=cdi-annotations,cdi-cri` and containerd 2.x has CDI
enabled by default, so the card is injected through a CDI spec in `/var/run/cdi` rather
than through the runtime handler. The `nvidia`, `nvidia-cdi` and `nvidia-legacy`
RuntimeClasses the Operator creates are there for workloads that want to select a
handler explicitly; nothing here has to.

**The end state is asserted, not hoped for.** The play waits for the node to actually
advertise `nvidia.com/gpu` before it moves on, up to twenty minutes on a first bootstrap
because the toolkit, device plugin, DCGM and validator images are several GB between them.
Every step before it can succeed while that stays false — a toolkit DaemonSet that wrote
containerd but could not restart it, a device plugin running without the nvidia runtime and
so seeing no devices — and each of those leaves a healthy-looking cluster where nothing can
ever request a GPU.

**No time-slicing.** One card is advertised as one GPU. Sharing it is a memory decision
before it is a scheduling one — time-slicing hands every pod the whole card with no memory
isolation and no queueing — so it stays off until something actually needs to share, and
the reasoning is written down in the chart's `values.yaml` beside the setting that would
turn it on. MIG is off for a simpler reason: this card has none.

## Scripts

Each script carries a shebang and is executable, so run it directly.

| Script | What it does |
| --- | --- |
| `install_ansible.sh` | Installs Ansible from the PPA on the control node. Ansible only — the two Galaxy collections the play needs are `build_cluster.sh`'s job, so a hand-run bootstrap installs them separately. See [Bootstrap](#bootstrap). |
| `install_ssh.sh` | Installs and enables `sshd`. |
| `check_deployments.sh` | Renders every chart in `system-apps/` and `deployment/` the way its deployer will and asserts the invariants that have bitten this cluster before. Run before pushing changes to either — though [CI](#ci) and `build_cluster.sh` both run it too, so forgetting is no longer silent. |
| `recover_cilium.sh` | Unsticks a Cilium that is CrashLooping against the API server ClusterIP. Fix `k8sServiceHost` in `values.yaml` and re-run the playbook afterwards — the patches are a stopgap, and the playbook is now the only thing that renders Cilium. |
| `recover_apiserver.sh` | Clears a static pod wedged in `CreateContainerError` after a backward clock step. Needs root and `crictl`. |
| `build_cluster.sh` | Builds the cluster from a fresh machine: installs Ansible and its collections, repairs a half-configured apt source if an earlier run left one, runs `check_deployments.sh`, runs the playbook, then prints the finished cluster's end state. Run as the login user, not with `sudo`. Flags in [Bootstrap](#bootstrap). |
| `destroy_cluster.sh` | Removes the cluster *and everything installed to run it* — packages, Helm, `crictl`, the apt repo, the host tuning, and the GPU Operator's node state under `/usr/local/nvidia` and `/run/nvidia` — then asserts the machine is actually clean. `--keep-packages` stops at the reset-and-clear-node-state line instead, leaving the packages and host tuning for the playbook to rebuild onto. Prompts before it starts; `-y`/`--yes` skips that. Leaves Ansible, chrony, Docker and the GPU driver alone — but the `time-sync` drop-ins it wrote are host tuning and do go. Run as the login user, not with `sudo`. |

### The clock

`recover_apiserver.sh` exists because of a failure worth understanding rather than just
recovering from (#21): `kube-apiserver` sat in `CreateContainerError` for nine hours while
the API server it represents was healthy and serving the whole time.

chrony ships with `makestep 1 3`, so it *steps* the clock outright for its first few
updates after boot. If kubelet and containerd are already recording container lifecycle
timestamps when that jump happens, their bookkeeping comes out inverted — a container
finishing hours before it started — and kubelet can conclude a healthy container died. It
then retries `CreateContainer` forever against a name reservation held by a half-created
container. That wedge survives restarting either daemon, because containerd re-reserves
the name from the orphan's record in bolt on startup, so the obvious fix does not work.

**The play prevents it**, in the Clock block: it installs chrony, enables `chrony-wait`
— which blocks until the clock is within 0.1s, and is what makes `time-sync.target` mean
anything — and drops `After=time-sync.target` into both `kubelet.service.d` and
`containerd.service.d`.

The cost is worth knowing: on a boot where NTP is unreachable, both daemons start up to
180s late, bounded by `chrony-wait`'s own `TimeoutStartSec`. The boot does not hang.

There is still no signal when the underlying wedge happens. The node stayed in that state
for nine hours unnoticed, and ArgoCD reported `Synced/Healthy` throughout — because the
controller that would have said otherwise was itself down.

### crictl

`recover_apiserver.sh` and `destroy_cluster.sh` both need `crictl`, and
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

## CI

[`.github/workflows/check-deployments.yml`](.github/workflows/check-deployments.yml) runs
`check_deployments.sh` on every pull request and every push to `main` touching
`deployment/`, `system-apps/`, `playbook.yml`, the script itself, or the workflow. The
script's own header says "run before pushing", which is advice; this is what makes the
invariants hold for anything that reaches `main`.

Both halves need it, for opposite reasons. ArgoCD syncs `deployment/` straight from `main`
with `prune` and `selfHeal`, so whatever merges there is applied within minutes and there
is no staging step in between. `system-apps/` waits for someone to re-run the playbook —
slower, but nothing reconciles behind it either, so a bad value sits in `main` looking
correct until the next bootstrap picks it up. That is a longer fuse, not a shorter one.

The workflow installs Helm by reading `helm_version` and `helm_sha256` back out of
`playbook.yml` rather than restating them, so CI renders with the same Helm the cluster was
built with and there is one place to bump. Third-party actions are pinned by commit rather
than by tag, on the same reasoning that replaced `get-helm-3` with a checksummed release
tarball (#31): a tag is mutable and would let the action change underneath us.

This is a signal, not a merge gate. Nothing stops a red run being merged — so do not sail
past one. For the ingress pin specifically, that run going red is the warning that arrives
*before* the cluster's, which is `IPAMRequestSatisfied=False` and every Ingress dead.
