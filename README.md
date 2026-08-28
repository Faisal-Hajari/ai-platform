# ai-platform
System for serving AI models over k8s

## Layout

- `infrastructure/k8s-ansible/` — the Ansible play that bootstraps the node: containerd,
  kubeadm, Cilium (as the CNI *and* the ingress controller, with kube-proxy skipped) and
  ArgoCD.
- `deployment/` — the charts and manifests ArgoCD syncs. The ApplicationSet in
  `infrastructure/k8s-ansible/argocd/applicationset.yaml` picks them up from here.
- `infrastructure/scripts/` — operational scripts, described below.

## Bootstrap

```bash
bash infrastructure/scripts/install_ansible.sh
ansible-playbook -i inventory.ini playbook.yml -e repo_path=$PWD/../..
```

Run the playbook from `infrastructure/k8s-ansible/`; `repo_path` is the repository root,
which the play reads Cilium's values and the ApplicationSet from.

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
It is not packaged on Ubuntu; install it from cri-tools:

```bash
VERSION=v1.31.1
curl -fsSL -o crictl.tar.gz "https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz"
sudo tar zxvf crictl.tar.gz -C /usr/local/bin && rm -f crictl.tar.gz
```
