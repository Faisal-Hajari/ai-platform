# system-apps

What ArgoCD needs in order to run. The Ansible play in `../playbook.yml` deploys
everything here; ArgoCD deploys everything in `deployment/`. That is the whole boundary,
and it is a directory rather than a per-Application exception so that nothing has to
remember it.

## The membership rule

**`system-apps/` holds only what ArgoCD needs in order to run.** That set has exactly two
members: the CNI, and ArgoCD itself.

cert-manager, metrics-server, monitoring, and anything else that merely feels "systemy"
does not qualify and belongs in `deployment/`. The test is not importance and not blast
radius — it is whether ArgoCD could reconcile the thing at all. Without a CNI no pod
reaches the API server, so ArgoCD cannot be the thing that installs one; ArgoCD cannot
bootstrap itself either. Everything else can be reconciled, and should be.

This is written down because the alternative is folklore. Without a stated criterion this
directory becomes the place things go when GitOps feels risky, and workloads that should
have a reconciler quietly lose one. Adding a third member means arguing that ArgoCD
cannot start without it — not that it would be inconvenient if it broke.

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
  argocd/
    applicationset.yaml
```

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

**ArgoCD's directory holds `applicationset.yaml` alone.** ArgoCD installs from a pinned
upstream URL (`v3.3.11`, in `../playbook.yml`) and that 20k-line manifest is not worth
vendoring. This leaves the two entries uneven — one is a chart plus values, the other a
URL plus a manifest. Moving ArgoCD to its Helm chart with a pinned version and a
`values.yaml` would make every entry the same shape and finally give ArgoCD's own
configuration a home in git; it is the better end state and a larger change than this
one, so it is deliberately left as a follow-up.

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
migration as `infrastructure/scripts/nuke_cluster.sh` plus a rebuild sidesteps both
questions and exercises the new bootstrap path, which needs testing regardless.
