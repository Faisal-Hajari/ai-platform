# deployment

Everything ArgoCD syncs. The ApplicationSet in
[`../infrastructure/k8s-ansible/system-apps/argocd/applicationset.yaml`](../infrastructure/k8s-ansible/system-apps/argocd/applicationset.yaml)
generates one Application per `deployment/<namespace>/<chart>` directory, tracking `main`
with `prune` and `selfHeal` on.

**This directory is empty right now, and that is not breakage.** Cilium and the
LoadBalancer configuration used to live here and have moved to
[`../infrastructure/k8s-ansible/system-apps/`](../infrastructure/k8s-ansible/system-apps/README.md),
which is deployed by the Ansible play instead — the CNI cannot be reconciled by a
controller that runs on top of it. The generator therefore matches nothing and generates
zero Applications until `deployment/ai-services/` gets content. The playbook still
asserts that the ApplicationSet resolved its generator, which is what proves ArgoCD can
clone the repo; an empty result is a successful resolution.

Anything that can be reconciled belongs here rather than in `system-apps/` — that
directory's README states the membership rule, and it is deliberately narrow.

Adding a chart:

- Put it at `deployment/<namespace>/<chart>/`. The Application is named
  `<namespace>-<chart>`; the leaf directory alone is not unique.
- Run [`../infrastructure/scripts/check_deployments.sh`](../infrastructure/scripts/check_deployments.sh)
  before pushing. It renders every chart the way ArgoCD will.
- `charts/` and `Chart.lock` are gitignored — they are `helm dependency update` output,
  resolved by ArgoCD's repo-server at sync time.

`check_deployments.sh` used to fail when this directory matched no charts. That check went
away with the move — it would now fire on every run — which means a chart *disappearing*
from here is no longer reported by anything. The Cilium half is still covered, by the
cross-file pool check that names the chart it needs; nothing equivalent guards a future
entry, so notice it when the first one lands.
