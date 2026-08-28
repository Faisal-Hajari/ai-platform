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
