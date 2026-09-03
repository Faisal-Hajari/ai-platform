# system-apps

What ArgoCD cannot safely reconcile. The Ansible play in `../playbook.yml` deploys
everything here; ArgoCD deploys everything in `deployment/`. That is the whole boundary,
and it is a directory rather than a per-Application exception so that nothing has to
remember it.

## The membership rule

**`system-apps/` holds two kinds of thing, and nothing else:**

1. **What ArgoCD needs in order to run** — the CNI, and ArgoCD itself.
2. **What writes the node's container runtime configuration** — today, the GPU Operator.

cert-manager, metrics-server, monitoring, and anything else that merely feels "systemy"
does not qualify and belongs in `deployment/`. The test is not importance and not blast
radius.

For clause 1 the test is whether ArgoCD could reconcile the thing at all. Without a CNI no
pod reaches the API server, so ArgoCD cannot be the thing that installs one; ArgoCD cannot
bootstrap itself either.

For clause 2 the test is narrower than it looks: does it rewrite `/etc/containerd` and
restart containerd? The generator's template applies `prune: true` and `selfHeal: true`,
so anything under `deployment/` is reconciled by a controller running on the runtime it is
editing — which is the same objection that moved the CNI out, one layer down. The GPU
Operator's toolkit DaemonSet does exactly that, so it is here.

**Clause 2 was added, not assumed, and it is the honest cost of choosing the GPU
Operator.** The bar this README used to state — argue that ArgoCD cannot start without it
— is one the Operator cannot clear: ArgoCD reconciles perfectly well on a cluster with no
GPU. A bare device plugin in `deployment/` would have satisfied the old rule and needed no
widening, at the price of hand-rolling the container toolkit and the containerd runtime
handler in Ansible. Running the stack NVIDIA actually supports was judged worth one more
clause. Widening it *silently* would not have been.

This is written down because the alternative is folklore. Without a stated criterion this
directory becomes the place things go when GitOps feels risky, and workloads that should
have a reconciler quietly lose one. A fourth member means arguing it fits one of the two
clauses above — not that it would be inconvenient if it broke, and not that it is easier
to reason about here.

## Why the boundary is a directory

The ApplicationSet generator's path is `deployment/*/*`. It cannot reach anything here,
so there is no exclusion list, no `{{path.basename}}` conditional, and no way to re-match
these directories by accident. The generator stays dumb.

Before this, Cilium sat in `deployment/kube-system/cilium` only because that is where it
was first put — and the generator's template applies `prune: true` and `selfHeal: true`,
so the CNI was reconciled by a controller that runs on top of it. ArgoCD was outside
`deployment/` for the same non-reason: nobody had put it there.

## What is in here

```
system-apps/
  cilium/
    Chart.yaml        umbrella over the upstream cilium chart, version pinned
    values.yaml       the whole configuration, including three host-specific values
    config/
      ip-pool.yaml    CiliumLoadBalancerIPPool
      l2-policy.yaml  CiliumL2AnnouncementPolicy
  gpu-operator/
    Chart.yaml        umbrella over NVIDIA's gpu-operator chart, version pinned
    values.yaml       three overrides and the reasoning for every default left alone
  argocd/
    Chart.yaml        umbrella over the upstream argo-cd chart, version pinned
    values.yaml       ArgoCD's own configuration
    applicationset.yaml
```

**The GPU Operator owns the whole GPU stack above the driver.** It installs the NVIDIA
container toolkit onto the node, writes containerd's `nvidia` runtime handler, creates the
`RuntimeClass` that selects it, and runs the device plugin that publishes `nvidia.com/gpu`
into the node's allocatable resources — plus DCGM metrics and node feature discovery. The
play configures none of that itself, deliberately: `toolkit.enabled` is on, so there is one
writer of the runtime handler, the same single-renderer rule Cilium is held to.

The driver is the exception, and it is the host's. `driver.enabled` is off, because the
Operator's driver component builds a kernel module in a container and this machine already
has a driver in that slot. The play asserts `nvidia-smi -L` lists a card before it touches
anything, so a driverless host fails in the first seconds rather than twenty minutes into
an image pull.

Three values in `gpu-operator/values.yaml` are load-bearing enough that
`../../scripts/check_deployments.sh` asserts them against the rendered `ClusterPolicy`
rather than trusting the file: `driver.enabled` false, `toolkit.enabled` true,
`devicePlugin.enabled` true. Each of the three fails late and confusingly if it flips —
a second kernel module, no containerd configuration at all, or a twenty-minute wait for a
resource nothing will publish.

Worth knowing before reading `/etc/containerd/conf.d/99-nvidia.toml` on the node: that
drop-in is not four keys about the nvidia runtime. It is a snapshot of the **entire** CRI
plugin section as the toolkit container resolved it — `cdi_spec_dirs`, `enable_cdi`, the CNI
block, every default beside the runtimes — and an import overrides. So a containerd upgrade
that moves any of those defaults is silently held to the values frozen when the toolkit last
ran. Re-running the play re-runs the toolkit DaemonSet, which is the fix; it is a reason to
re-run after a containerd bump rather than to assume nothing changed.

**The Operator writes node state that no Ansible task and no `git grep` can find.** Its
toolkit DaemonSet unpacks into `/usr/local/nvidia` and writes a containerd drop-in from
inside a container. It reverts both on a graceful `SIGTERM` — the installer traps it and
unconfigures containerd on the way out — but `kubeadm reset` never delivers one, so
`../../scripts/destroy_cluster.sh` removes those paths by hand and asserts they are gone.

That is observed rather than assumed. A teardown of this cluster logs a `StopPodSandbox
... DeadlineExceeded` for *every* sandbox on the node and ends on `[reset] Failed to
remove containers`, because `kubeadm reset` drives the CRI while the CNI agent is
already gone. Nothing on the node is stopped cleanly, the toolkit DaemonSet included —
so its own revert path never runs, and the hand-rolled cleanup is doing real work rather
than duplicating it. The stall is not GPU-specific and predates this chart, but it
scales with pod count and the Operator roughly doubles that.

That is the concrete price of clause 2, and it is the thing most likely to rot: if a future
Operator version changes where it installs, that script is what has to follow.

**Cilium is rendered once.** `helm upgrade --install` against `cilium/`, from
`cilium/values.yaml`, and nothing else. It used to be rendered twice — the Cilium CLI at
bootstrap with eight hand-written `--set` flags, and the same chart again inside ArgoCD —
with only the ingress IP and the pod CIDR read across from one to the other. Every other
setting existed in two places that agreed by hand, which is how `k8sServiceHost` drifted
and why `../../scripts/recover_cilium.sh` exists. `prune`/`selfHeal` were the delivery
mechanism; the double render was the cause.

**`config/` is part of the Cilium unit**, applied by the same playbook step, ordered
after the CRDs the operator registers. The ingress address pinned in `values.yaml` has to
sit inside the pool declared in `config/ip-pool.yaml`; as two separately-synced
Applications with no ordering between them, that pair could disagree transiently even
when both files were individually correct.

The pool has a second constraint that is not in this repo at all: `config/l2-policy.yaml`
announces those addresses over ARP on one named interface, and they only reach the LAN
while the pool sits on the subnet that interface is attached to. That subnet is a DHCP
lease on the node and nothing in git states it, so the two halves are checked in two
places — `../../scripts/check_deployments.sh` asserts that a policy exists and announces
LoadBalancer addresses, and `../playbook.yml` resolves the interfaces the policy matches
on the host and refuses to build anything if the pool is off their subnets. Both matter
because the cluster reports none of it: LB-IPAM allocates, the Service gets an
`EXTERNAL-IP`, and the address is unreachable.

The order the play uses is load-bearing and worth knowing before editing it:

1. `helm upgrade --install`, **without `--wait`**. Helm counts a LoadBalancer Service as
   not-ready until `.status.loadBalancer.ingress` is populated, and this chart renders
   `kube-system/cilium-ingress` as one with no `spec.externalIPs`. That address comes from
   LB-IPAM, which needs the pool in step 4 — so `--wait` here waits for something only a
   later step can cause, times out, and leaves the release with a failed *install*
   revision that makes every subsequent `helm upgrade --install` exit with `has no
   deployed releases`.
2. `rollout status` on `ds/cilium`, `deploy/cilium-operator` and `ds/cilium-envoy` — the
   wait that `--wait` was actually being used for, asked about the datapath rather than
   about every object in the release. Envoy is in the list because it serves the L7
   Ingress path; step 5 proves the shared entrypoint has an address, not that anything is
   listening behind it. Two edits would break this step rather than slow it: all three
   render `RollingUpdate`, and `kubectl rollout status` hard-errors on `OnDelete`; and
   `ds/cilium-envoy` exists only while `envoy.enabled` is true, which `values.yaml` never
   states — it rides the upstream default, so a `cilium` version bump in `Chart.yaml` that
   flipped it would fail here with a bare NotFound. Pinning `envoy.enabled` would state
   that dependency in the right place but silently override whatever a future chart's
   default comes to mean, so it is documented rather than pinned.
3. Poll for the two CRDs, then wait for `Established`. `cilium-operator` registers them at
   runtime; the chart does not ship them under `crds/`.
4. `kubectl apply -f config/`.
5. Wait for `cilium-ingress` to be served an address. A pin outside the pool leaves
   LB-IPAM with `IPAMRequestSatisfied=False`, no address on the Service, and every Ingress
   in the cluster dead — with no reconciler behind the play, a run that went green here
   would be the last thing to notice.

**Both entries are the same shape**: a chart with a pinned version and a `values.yaml`.
ArgoCD used to install from a pinned `raw.githubusercontent.com` URL (`v3.3.11`) held as a
literal in `../playbook.yml`, which left it uneven with Cilium and cost three things.
There was nowhere to put an ArgoCD setting, so RBAC, SSO and repo-server tuning all meant
patching a live cluster with nothing in git. `../../scripts/check_deployments.sh` globs
`system-apps/*/Chart.yaml`, so a directory without one was never rendered or checked. And
the version sat where no tooling could read it. `argocd/Chart.yaml` fixes all three.

The chart's version and ArgoCD's are different numbers: `argo-cd` 10.6.4 ships ArgoCD
v3.5.2, and no chart in that repository ever shipped v3.3.11 — argo-helm's 3.3 line stops
at appVersion v3.3.9 while upstream ArgoCD went on past it. The move therefore could not
carry the old pin across, and taking the current chart was the only option that did not
also mean adopting a chart line that receives no further releases.

`applicationset.yaml` stays a plain manifest beside the chart rather than becoming a
template inside it. The play reads it with `lookup('file')` in `pre_tasks` and asserts on
its parsed contents *before* the bootstrap runs, which is what makes a bad repo URL fail
in the first ten seconds rather than 400 lines in; a Helm template is not YAML until it is
rendered, and rendering it would need the chart, the node and a cluster to install into.
Helm ignores files outside `templates/`, so it sits there inertly.

## Accepted trade-offs

**No drift visibility.** Keeping Cilium in ArgoCD under a manual sync policy would have
shown divergence as OutOfSync-without-applying. Ansible-only means nothing reports
divergence until someone re-runs the playbook. Judged acceptable because after this
change the set of things that mutate Cilium is approximately empty — but it is a
decision, not a side effect.

**No prune under `config/`.** The playbook applies those manifests with `kubectl apply
-f`, which has no prune: deleting a pool from git leaves it in the cluster. Acceptable
for two small manifests; removing one means also deleting it by hand.

**Re-running the playbook is the only update path**, so everything here has to be
idempotently re-runnable. `helm upgrade --install` is its own guard and `kubectl apply`
is idempotent; do not reintroduce a `creates:` guard over either. The old Cilium task
carried one (`creates: /etc/cni/net.d/05-cilium.conflist`) which made the bootstrap
one-shot: Ansible skipped the whole task once the conflist existed, so the `cilium
upgrade` branch inside it was unreachable and ArgoCD was the only thing that could change
Cilium on a live cluster.

The dependency resolve before it *is* gated, and that is not the same thing: it is a
cache fill, keyed on the exact `name-version.tgz` that `Chart.yaml` declares, so bumping
the pinned version resolves again while a re-run that changes nothing does not need
`helm.cilium.io` to be reachable. (`helm dependency build` would not do: it re-downloads
even against a matching `Chart.lock` and a populated `charts/`, `--skip-refresh`
included.)

## Changing something here

```bash
bash infrastructure/scripts/check_deployments.sh   # renders these charts, asserts the invariants
cd infrastructure/k8s-ansible
ansible-playbook -i inventory.ini playbook.yml --ask-vault-pass
```

The playbook reads the **local checkout**, not `main`. That was a hazard while ArgoCD
tracked `main` behind it; now it just means a change takes effect where it was made, and
should still be merged so the next machine gets it.

## Migrating a live cluster onto this layout

Removing `deployment/kube-system/cilium/` from git is exactly the operation that makes
the git generator drop the Applications it produced. Whether that orphans the CNI or
deletes it depends on the `resources-finalizer.argocd.argoproj.io` finalizer, which the
ApplicationSet template does not set — verify rather than assume, **before** pushing:

```bash
kubectl -n argocd get application kube-system-cilium kube-system-cilium-config -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.finalizers}{"\n"}{end}'
```

Empty output means the resources are orphaned and the move is safe on a live cluster; the
playbook then re-adopts them. Non-empty means merging the move deletes the datapath, and
nothing inside the cluster can undo that.

Note also that `helm upgrade --install cilium` adopts the release the Cilium CLI created
(same name, same namespace) but changes the chart under it, and Helm refuses to take over
resources that carry no `meta.helm.sh/release-name` ownership metadata. Sequencing the
migration as `infrastructure/scripts/destroy_cluster.sh --keep-packages` plus a rebuild
sidesteps both questions and exercises the new bootstrap path, which needs testing
regardless.

**ArgoCD has the same problem and no equivalent escape hatch.** On a cluster built before
it moved to the chart, every ArgoCD object was created by `kubectl apply` and carries no
Helm ownership metadata, so the first `helm upgrade --install argocd` fails on ownership
rather than adopting them. Annotating them by hand is not the fix — there are hundreds of
objects, and getting one wrong leaves a release Helm believes owns something it does not.
Take the same rebuild path; the play asserts on this and says so when the install fails.
Note also that the chart's CRDs carry `helm.sh/resource-policy: keep`, so `helm uninstall
argocd` on its own leaves `applications.argoproj.io` and its siblings behind — along with
every Application stored in them.
