#!/usr/bin/env bash
# Builds the cluster on a fresh machine, end to end.
#
# Usage: ./infrastructure/scripts/build_cluster.sh [options]
#
# The playbook is the thing that builds the cluster; this script is everything that has
# to be true before `ansible-playbook` can be run at all, plus the checks that turn the
# ways it silently half-works into a message. README.md's Bootstrap section is the same
# two commands by hand -- this exists because "by hand" was three undocumented
# prerequisites (crictl, a vault, a checkout at the path group_vars guesses) and a
# playbook that only tells you about the third of them once it is 500 lines in.
#
# Deliberately NOT run as root. The playbook is `become: true` and takes its sudo
# password from the vault, and roughly half its tasks are `become: false` because they
# write into the operator's home -- ~/.kube/config, and the chart's charts/ cache under
# repo_path. Running the whole thing as root leaves both root-owned, which breaks the
# operator's own kubectl and every later `helm dependency update`.
#
# Idempotent: every step checks before it acts, so re-running after a failure resumes
# rather than redoing. `kubeadm init` is guarded by the playbook's own `creates:`.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ANSIBLE_DIR="$REPO_ROOT/infrastructure/k8s-ansible"
INVENTORY="$ANSIBLE_DIR/inventory.ini"
VAULT_FILE="$ANSIBLE_DIR/group_vars/k8s-master/vault.yml"

# Same pin as README.md's crictl block -- version and the SHA256 of the release artefact
# itself, per version and per architecture, so bumping VERSION means replacing both
# digests. Only amd64 and arm64 are pinned; anything else stops before the download
# rather than installing something unverified.
CRICTL_VERSION=v1.31.1
CRICTL_SHA256_amd64=0a03ba6b1e4c253d63627f8d210b2ea07675a8712587e697657b236d06d7d231
CRICTL_SHA256_arm64=cd70f9b2f75c9619f40450d4b6e2c74aaab619917da517eff6787b442f8b0e56

VAULT_ARGS=()
SKIP_RENDER_CHECK=0
ANSIBLE_EXTRA=()

usage() {
  cat <<'EOF'
Builds the Kubernetes cluster from a fresh machine.

  ./infrastructure/scripts/build_cluster.sh [options] [-- <extra ansible-playbook args>]

Options:
  --vault-password-file FILE  Read the vault password from FILE instead of prompting.
  --skip-render-check         Do not run check_deployments.sh before the playbook.
  -h, --help                  This message.

Anything after `--` is passed straight to ansible-playbook, so `-- --check` or
`-- -vvv` work.

Prerequisites this script installs if they are missing: Ansible, crictl.
Prerequisite it cannot create for you: group_vars/k8s-master/vault.yml, which must hold
vault_become_pass and vault_argocd_deploy_key. See the failure message if it is absent.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vault-password-file)
      [ $# -ge 2 ] || { echo "--vault-password-file needs a path" >&2; exit 2; }
      VAULT_ARGS=(--vault-password-file "$2"); shift 2 ;;
    --vault-password-file=*)
      VAULT_ARGS=(--vault-password-file "${1#*=}"); shift ;;
    --skip-render-check) SKIP_RENDER_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ANSIBLE_EXTRA=("$@"); break ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
# Default only if nothing was passed: --ask-vault-pass and --vault-password-file are
# mutually exclusive and ansible-playbook errors when given both.
[ ${#VAULT_ARGS[@]} -gt 0 ] || VAULT_ARGS=(--ask-vault-pass)

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────
# Everything here is decidable before anything is installed or changed. A fresh machine
# that is going to fail should fail while it is still fresh.
step "Preflight"

[ "$(id -u)" -ne 0 ] || die "do not run this as root -- see the header comment. Run it as the
    login user named in inventory.ini; it calls sudo where it needs to."

# `sudo -v` rather than a later surprise: this script installs packages, and the
# playbook's become password comes from the vault, so an operator with no sudo rights
# gets a password prompt loop hundreds of tasks in.
#
# It also pins down where this has to be run from. `sudo -v` prompts on a terminal, so
# with no TTY -- a CI job, `ssh host ./build_cluster.sh`, a pipe -- it fails with
# "a terminal is required" and this is the message that explains it. The playbook's own
# --ask-vault-pass has the same requirement, so there is no getting further anyway
# without both an askpass helper and --vault-password-file.
sudo -v || die "this script needs sudo, on a terminal.
    If there is no TTY here (CI, a piped ssh command), sudo cannot prompt: give the
    operator NOPASSWD or set SUDO_ASKPASS and export SUDO_ASKPASS-aware sudo, and pass
    --vault-password-file so the vault does not prompt either."

# install_ansible.sh has carried a comment about this for a while; on Ubuntu 26.04 it is
# no longer hypothetical, because sudo-rs is a packaged alternative for /usr/bin/sudo.
# Ansible's become plugin drives sudo with flags sudo-rs does not implement, and the
# failure is an opaque "sudo: invalid option" on the first become task.
if ! sudo --version 2>&1 | head -1 | grep -qi '^sudo version'; then
  die "/usr/bin/sudo is not the classic sudo (probably sudo-rs), which Ansible cannot
    drive. Switch it with:
        sudo update-alternatives --config sudo
    or install the classic one: sudo apt install sudo"
fi

[ -f "$INVENTORY" ] || die "no inventory at $INVENTORY -- is $REPO_ROOT really the checkout?"
[ -f "$ANSIBLE_DIR/playbook.yml" ] || die "no playbook at $ANSIBLE_DIR/playbook.yml"

# inventory.ini pins ansible_user, and group_vars derives both repo_path and the
# ~/.kube/config path from it. Running as anyone else builds a cluster whose kubeconfig
# lands in a home the operator does not own. Checked here rather than discovered as a
# permissions error 400 tasks in.
inventory_user=$(sed -n 's/.*ansible_user=\([^ ]*\).*/\1/p' "$INVENTORY" | head -1)
if [ -n "$inventory_user" ] && [ "$inventory_user" != "$(id -un)" ]; then
  die "inventory.ini names ansible_user=$inventory_user but this is $(id -un).
    The kubeconfig and the chart cache are written into that user's home. Either run as
    $inventory_user, or edit $INVENTORY."
fi

if [ ! -f "$VAULT_FILE" ]; then
  die "no vault at $VAULT_FILE.
    The playbook cannot load group_vars without it. Create it with:
        ansible-vault create $VAULT_FILE
    and put two keys in it:
        vault_become_pass: <the sudo password for $(id -un)>
        vault_argocd_deploy_key: |
          <private half of a GitHub deploy key with read access to this repo>
    Generate the key with \`ssh-keygen -t ed25519 -N '' -C argocd -f argocd_deploy_key\`
    and add the .pub half under the repo's Deploy keys on GitHub. -N '' is not optional:
    ArgoCD has nowhere to enter a passphrase."
fi
head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT' \
  || die "$VAULT_FILE is not vault-encrypted. It holds a sudo password and a private key;
    encrypt it with \`ansible-vault encrypt $VAULT_FILE\` before going further."
info "vault present and encrypted"

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "no pinned crictl/Helm artefact for $(uname -m). Add one to this script and to
    the vars at the top of playbook.yml." ;;
esac
info "architecture $ARCH"

command -v curl >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y curl; }

# ── Ansible ───────────────────────────────────────────────
step "Ansible"
if command -v ansible-playbook >/dev/null; then
  info "already installed: $(ansible-playbook --version | head -1)"
else
  "$REPO_ROOT/infrastructure/scripts/install_ansible.sh"
fi

# The playbook uses ansible.posix.sysctl and community.general.modprobe. The `ansible`
# package carries both; `ansible-core` alone does not, and the run then dies on the
# first of them with "couldn't resolve module/action" -- after swap is already off and
# fstab is already rewritten. Checked up front, and repaired from Galaxy rather than
# just reported, because ansible-core is what pip installs by default.
step "Ansible collections"
for collection in ansible.posix community.general; do
  if ansible-galaxy collection list "$collection" 2>/dev/null | grep -q "^$collection "; then
    info "$collection present"
  else
    info "$collection missing -- installing from Galaxy"
    ansible-galaxy collection install "$collection"
  fi
done

# ── crictl ────────────────────────────────────────────────
# Needed by kubeadm reset (which drives the CRI through it and reports success without
# it), by recover_apiserver.sh, and by destroy_cluster.sh. Not packaged on Ubuntu, and
# until now only documented in README.md -- so a fresh machine reached teardown before
# discovering it, which is the worst moment to find out.
step "crictl"
if command -v crictl >/dev/null && crictl --version | grep -q "$CRICTL_VERSION"; then
  info "already at $CRICTL_VERSION"
else
  sha_var="CRICTL_SHA256_$ARCH"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/crictl.tar.gz" \
    "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$ARCH.tar.gz"
  echo "${!sha_var}  $tmp/crictl.tar.gz" | sha256sum -c -
  sudo tar zxf "$tmp/crictl.tar.gz" -C /usr/local/bin crictl
  rm -rf "$tmp"
  trap - EXIT
  info "installed $(crictl --version)"
fi

# ── Static checks ─────────────────────────────────────────
# Renders both halves and asserts the cross-file invariants. Needs helm, which the
# playbook installs -- so on a genuinely fresh machine this is skipped rather than
# failed, and the same checks run in CI on every change to the charts anyway.
if [ "$SKIP_RENDER_CHECK" -eq 0 ]; then
  step "Static checks (check_deployments.sh)"
  if command -v helm >/dev/null; then
    "$REPO_ROOT/infrastructure/scripts/check_deployments.sh"
  else
    info "helm not installed yet -- skipping; the playbook installs it, re-run to check"
  fi
fi

# ── The playbook ──────────────────────────────────────────
# -e repo_path is the fix for the one prerequisite nothing else states. group_vars
# defaults it to /home/<user>/dev/ai-platform, which is a guess about where the checkout
# lives: from any other path -- a second clone, a git worktree, /opt -- the play silently
# reads system-apps/ out of the *guessed* directory and deploys whatever is on disk
# there, not what you are looking at. Passing the resolved root makes the play deploy the
# checkout it was launched from.
step "Running the playbook"
info "repo_path=$REPO_ROOT"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory.ini playbook.yml \
  -e "repo_path=$REPO_ROOT" \
  "${VAULT_ARGS[@]}" \
  ${ANSIBLE_EXTRA[@]+"${ANSIBLE_EXTRA[@]}"}

# ── Post-verify ───────────────────────────────────────────
# The playbook asserts its own steps; this asserts the result as an operator would see
# it, from the kubeconfig it just installed. Nothing here is a duplicate of a play
# assert: it is the same questions asked of the finished cluster, so a green play over a
# cluster that is not actually usable does not read as success.
step "Verifying the cluster"
export KUBECONFIG="$HOME/.kube/config"
[ -r "$KUBECONFIG" ] || die "the playbook did not leave a readable $KUBECONFIG"

verify_fail=0
check() {
  local label=$1; shift
  if out=$("$@" 2>&1); then
    printf '    ok   %-38s %s\n' "$label" "$(printf '%s' "$out" | head -1)"
  else
    printf '    FAIL %-38s %s\n' "$label" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    verify_fail=1
  fi
}

check "node Ready"            kubectl wait --for=condition=Ready node --all --timeout=120s
check "cilium agent"          kubectl -n kube-system rollout status ds/cilium --timeout=120s
check "cilium operator"       kubectl -n kube-system rollout status deploy/cilium-operator --timeout=120s
check "argocd server"         kubectl -n argocd rollout status deploy/argocd-server --timeout=120s
check "applicationset generator" kubectl -n argocd wait --for=condition=ResourcesUpToDate \
      applicationset/deployment-appset --timeout=120s

# The ingress address is the one thing a green play can still get wrong in a way nothing
# else reports, and the answer is worth printing rather than merely asserting -- it is the
# A record every Ingress in the cluster resolves to.
ingress_ip=$(kubectl -n kube-system get service cilium-ingress \
               -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [ -n "$ingress_ip" ]; then
  printf '    ok   %-38s %s\n' "ingress address" "$ingress_ip"
else
  printf '    FAIL %-38s %s\n' "ingress address" "cilium-ingress has none -- LB-IPAM could not serve the pin"
  verify_fail=1
fi

if [ "$verify_fail" -ne 0 ]; then
  die "the playbook finished but the cluster does not check out -- see the FAILs above."
fi

step "Cluster is up"
cat <<EOF
    kubeconfig      $KUBECONFIG
    ingress         $ingress_ip
    argocd password kubectl -n argocd get secret argocd-initial-admin-secret \\
                      -o jsonpath='{.data.password}' | base64 -d
    argocd UI       kubectl -n argocd port-forward svc/argocd-server 8080:443

    Re-running this script is the only update path for anything under system-apps/.
    To tear it all down: infrastructure/scripts/destroy_cluster.sh
EOF
