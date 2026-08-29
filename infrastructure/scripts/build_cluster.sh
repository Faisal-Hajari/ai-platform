#!/usr/bin/env bash
# Builds the cluster on a fresh machine, end to end.
#
# Usage: ./infrastructure/scripts/build_cluster.sh [options]
#
# The playbook is what builds the cluster. This is the part that cannot be Ansible --
# getting Ansible itself onto the box, and checking the things that must be true before
# `ansible-playbook` can usefully start -- plus a short end-state summary afterwards.
#
# Everything that CAN be a task is one. crictl used to be installed here, in a bash
# reimplementation of the playbook's own pinned-download block; it is a play task now,
# sharing that block's architecture resolution and checksum assert. The play also locates
# its own charts (`playbook_dir`), so there is no repo_path to pass.
#
# Deliberately NOT run as root. The playbook is `become: true` and takes its sudo password
# from the vault, and roughly half its tasks are `become: false` because they write into
# the operator's home -- ~/.kube/config, and the chart's charts/ cache inside the checkout.
# Running the whole thing as root leaves both root-owned, which breaks the operator's own
# kubectl and every later `helm dependency update`.
#
# Idempotent: every step checks before it acts, so re-running after a failure resumes.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ANSIBLE_DIR="$REPO_ROOT/infrastructure/k8s-ansible"
INVENTORY="$ANSIBLE_DIR/inventory.ini"
VAULT_FILE="$ANSIBLE_DIR/group_vars/k8s-master/vault.yml"
APPSET_FILE="$ANSIBLE_DIR/system-apps/argocd/applicationset.yaml"
CILIUM_VALUES="$ANSIBLE_DIR/system-apps/cilium/values.yaml"
K8S_KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
K8S_APT_LIST=/etc/apt/sources.list.d/kubernetes.list

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

Anything after `--` is passed straight to ansible-playbook, e.g. `-- -vvv`.
(`--check` is not usable against this play: most of it is command/shell, and check mode
skips the tasks the later ones read the results of.)

Prerequisites this installs if missing: Ansible and its two collections. Everything else
the node needs -- containerd, kubeadm, Helm, crictl -- is installed by the playbook.

group_vars/k8s-master/vault.yml is tracked in this repo, so it is already present after a
clone; what it cannot supply is its contents. It must hold vault_become_pass and
vault_argocd_deploy_key, and a vault missing either is reported by the play's own
pre_tasks within seconds, before the run touches the host.
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
warn() { printf '    \033[1;33mnote:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────
# Everything here is decidable before anything is installed or changed. A fresh machine
# that is going to fail should fail while it is still fresh.
step "Preflight"

[ "$(id -u)" -ne 0 ] || die "do not run this as root -- see the header comment. Run it as the
    login user named in inventory.ini; it calls sudo where it needs to."

# `sudo -v` prompts on a terminal, so with no TTY -- CI, `ssh host ./build_cluster.sh`, a
# pipe -- it fails with "a terminal is required" and this message explains it. The play's
# --ask-vault-pass has the same requirement.
sudo -v || die "this script needs sudo, on a terminal.
    If there is no TTY here (CI, a piped ssh command), sudo cannot prompt: give the
    operator NOPASSWD or set SUDO_ASKPASS, and pass --vault-password-file so the vault
    does not prompt either."

# Ansible's become plugin drives sudo with flags sudo-rs does not implement, and the
# failure is an opaque "sudo: invalid option" on the first become task -- which is
# Gathering Facts, since the play is `become: true` at play level, so no assert inside the
# play could ever report it.
#
# Asked of the binary rather than of a version banner. Sniffing `sudo --version` for
# "Sudo version" fails closed, which is the right direction, but it makes a wording change
# upstream brick the documented entry point with a confidently wrong diagnosis. What
# actually matters is which implementation is behind /usr/bin/sudo.
sudo_real=$(readlink -f "$(command -v sudo)" 2>/dev/null || echo "")
case "$sudo_real" in
  *sudo-rs*) die "/usr/bin/sudo resolves to $sudo_real (sudo-rs), which Ansible cannot
    drive. Switch it with:
        sudo update-alternatives --config sudo
    or install the classic one: sudo apt install sudo" ;;
esac

[ -f "$INVENTORY" ] || die "no inventory at $INVENTORY -- is $REPO_ROOT really the checkout?"
[ -f "$ANSIBLE_DIR/playbook.yml" ] || die "no playbook at $ANSIBLE_DIR/playbook.yml"

# inventory.ini pins ansible_user, and the play writes ~/.kube/config into that user's
# home. Running as anyone else builds a cluster whose kubeconfig the operator does not own.
#
# Comment lines skipped, and the value terminated on any whitespace rather than on a
# space: a commented-out host would otherwise win (`head -1` takes it), and a tab-separated
# inventory would swallow the rest of the line into the username. Both produce a confident
# `die` telling you to edit a file that is correct. `ansible-inventory --list` is the exact
# answer, but it needs the vault password, which is not available this early.
inventory_user=$(sed -e 's/[;#].*//' -e '/^[[:space:]]*$/d' "$INVENTORY" \
                 | sed -n 's/.*ansible_user=\([^[:space:]]*\).*/\1/p' | head -1)
if [ -n "$inventory_user" ] && [ "$inventory_user" != "$(id -un)" ]; then
  die "inventory.ini names ansible_user=$inventory_user but this is $(id -un).
    The kubeconfig and the chart cache are written into that user's home. Either run as
    $inventory_user, or edit $INVENTORY."
fi

[ -f "$VAULT_FILE" ] || die "no vault at $VAULT_FILE.
    It is tracked in this repo, so this means the checkout is incomplete."
head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT' \
  || die "$VAULT_FILE is not vault-encrypted. It holds a sudo password and a private key;
    encrypt it with \`ansible-vault encrypt $VAULT_FILE\` before going further."
info "vault present and encrypted (its *contents* are checked by the play's pre_tasks)"

# ── Repair a half-configured apt source ───────────────────
# This has to happen before anything runs `apt update`, and two steps below can:
# install_ansible.sh opens with one, and so does the curl fallback. An apt refresh
# validates every configured repository, including the Kubernetes one this repo's own play
# adds -- so a run that failed after writing kubernetes.list but before the keyring was
# usable leaves a machine where the *wrapper* cannot get far enough to reach the play that
# would repair it. The play closes this for itself; this closes it one level up.
step "Kubernetes apt source"
if [ -e "$K8S_APT_LIST" ] || [ -e "$K8S_KEYRING" ]; then
  keyring_ok=0
  if [ -e "$K8S_KEYRING" ] && sudo gpg --no-default-keyring --keyring "$K8S_KEYRING" \
       --list-keys --with-colons 2>/dev/null | grep -q '^pub:'; then
    keyring_ok=1
  fi
  if [ "$keyring_ok" -eq 1 ]; then
    # Valid keyring, possibly unreadable by the unprivileged `_apt` that runs gpgv.
    if [ "$(stat -c '%a' "$K8S_KEYRING")" != "644" ]; then
      sudo chmod 0644 "$K8S_KEYRING"
      info "repaired the mode on $K8S_KEYRING (was unreadable by _apt)"
    else
      info "keyring is present and readable"
    fi
  else
    # An empty or malformed keyring cannot be repaired, and leaving the list file pointing
    # at it makes every apt refresh fail. Remove both; the play recreates them atomically.
    sudo rm -f "$K8S_KEYRING" "$K8S_APT_LIST"
    info "removed an unusable keyring and its sources.list entry -- the play recreates them"
  fi
else
  info "not configured yet -- the play will add it"
fi

# Checked here rather than discovered at the end. The end-state block reads the
# ApplicationSet name and the ingress pin out of YAML with PyYAML, and that runs *after*
# the play has succeeded -- so on a box without it a working cluster ends this script with
# a ModuleNotFoundError under `set -e`. check_deployments.sh would normally surface it
# earlier, but on a fresh machine that is skipped for want of helm, so this is the first
# use. CI installs PyYAML explicitly, which is a good sign it should not be assumed here.
#
# Placed below the apt-source repair, not above it. `apt-get install` does not refresh the
# cache by default, so this would not fire the ordering problem today -- but that is a fine
# distinction to leave load-bearing three lines above the block whose whole purpose is to
# enforce the ordering, and this branch has twice found that an ordering assumption stated
# only in a comment is worth restating as position.
#
# It is also the only apt call ahead of `install_ansible.sh` now: the `command -v curl`
# fallback went with the crictl block, and that one did `update && install`. On a machine
# with empty apt lists a bare install would fail with no preceding refresh, so it refreshes
# first -- safe here because the repair above has already dealt with a broken
# kubernetes.list.
if python3 -c 'import yaml' 2>/dev/null; then
  info "PyYAML present"
else
  info "installing python3-yaml (the end-state check reads the charts with it)"
  sudo apt-get update -qq
  sudo apt-get install -y python3-yaml
fi

# ── Ansible ───────────────────────────────────────────────
step "Ansible"
if command -v ansible-playbook >/dev/null; then
  info "already installed: $(ansible-playbook --version | head -1)"
else
  "$REPO_ROOT/infrastructure/scripts/install_ansible.sh"
fi

# The play uses ansible.posix.sysctl and community.general.modprobe. The `ansible` package
# carries both; `ansible-core` alone does not, and the run dies on the first of them with
# "couldn't resolve module/action" -- after swap is off and fstab is rewritten.
#
# Asked with ansible-doc, which answers the question the play actually cares about (can
# this module resolve?) rather than parsing `ansible-galaxy collection list`, whose
# human-readable table -- header, a `# path` line, a `---` rule -- is not a stable
# interface.
step "Ansible collections"
for module in ansible.posix.sysctl community.general.modprobe; do
  if ansible-doc -t module "$module" >/dev/null 2>&1; then
    info "$module resolves"
  else
    collection=${module%.*}
    info "$module does not resolve -- installing $collection from Galaxy"
    ansible-galaxy collection install "$collection"
    ansible-doc -t module "$module" >/dev/null 2>&1 \
      || die "$collection installed but $module still does not resolve. Check
    ANSIBLE_COLLECTIONS_PATH and which ansible-playbook is on PATH ($(command -v ansible-playbook))."
  fi
done

# ── Static checks ─────────────────────────────────────────
# Renders both halves and asserts the cross-file invariants. Needs helm, which the play
# installs -- so on a genuinely fresh machine this is skipped rather than failed, and CI
# runs the same checks on every change to the charts.
if [ "$SKIP_RENDER_CHECK" -eq 0 ]; then
  step "Static checks (check_deployments.sh)"
  if command -v helm >/dev/null; then
    "$REPO_ROOT/infrastructure/scripts/check_deployments.sh"
  else
    info "helm not installed yet -- skipping; the play installs it, re-run to check"
  fi
fi

# ── The playbook ──────────────────────────────────────────
step "Running the playbook"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory.ini playbook.yml \
  "${VAULT_ARGS[@]}" \
  ${ANSIBLE_EXTRA[@]+"${ANSIBLE_EXTRA[@]}"}

# ── End state ─────────────────────────────────────────────
# Deliberately short. This used to re-asks five questions the play already blocks on, and
# got one of them wrong: it waited on deploy/argocd-server, which is precisely the gate the
# play argues is the wrong one (repo-server does the clone and the applicationset
# controller does the reconcile, and argocd-redis can lag both on a cold pull), so it would
# report ok while the components that matter were still starting.
#
# What is left is the operator's view of the finished cluster: the two facts worth printing
# rather than merely asserting, read through the kubeconfig the play just installed. Names
# come out of the same files the play reads, not restated here -- rename the ApplicationSet
# or repin the ingress and this follows, instead of failing on a healthy cluster.
step "End state"
export KUBECONFIG="$HOME/.kube/config"
[ -r "$KUBECONFIG" ] || die "the playbook did not leave a readable $KUBECONFIG"

appset_name=$(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["metadata"]["name"])' "$APPSET_FILE")
ingress_pin=$(python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["cilium"]["ingressController"]["service"]["annotations"]
print(v["lbipam.cilium.io/ips"])' "$CILIUM_VALUES")

verify_fail=0
# Quoted, and reading the Ready condition's *status* rather than its type. The previous
# form was `custom-columns=...,STATUS:.status.conditions[-1].type`, wrong twice: `[-1].type`
# is the string "Ready" -- the condition's name, printed identically for a NotReady node --
# and unquoted it is a glob, which zsh treats as a fatal "no matches found" rather than
# passing through as bash does, so the line did not run at all under zsh.
# destroy_cluster.sh already codifies that glob rule for its own `find`.
node_ready=$(kubectl get nodes --no-headers \
  -o "custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status" \
  2>&1 | tr '\n' ' ')
printf '    %-22s %s\n' "node Ready" "$node_ready"

appset_ready=$(kubectl -n argocd get applicationset "$appset_name" \
                 -o jsonpath='{.status.conditions[?(@.type=="ResourcesUpToDate")].status}' 2>&1 || true)
if [ "$appset_ready" = "True" ]; then
  printf '    %-22s %s\n' "applicationset" "$appset_name ResourcesUpToDate"
else
  printf '    %-22s %s\n' "applicationset" "FAIL: $appset_name is not ResourcesUpToDate ($appset_ready)"
  verify_fail=1
fi

# Compared against the pin, not merely checked for existence. #35 added a CI assert that
# the pinned address sits inside the LoadBalancer pool; this is the cluster-side half of
# the same claim -- an address that is not the pinned one means every ingress A record is
# wrong, which "has an address" would pass.
ingress_ip=$(kubectl -n kube-system get service cilium-ingress \
               -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [ "$ingress_ip" = "$ingress_pin" ]; then
  printf '    %-22s %s\n' "ingress" "$ingress_ip"
else
  printf '    %-22s %s\n' "ingress" "FAIL: serving '${ingress_ip:-<none>}', values.yaml pins $ingress_pin"
  verify_fail=1
fi

[ "$verify_fail" -eq 0 ] || die "the playbook finished but the cluster does not check out."

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
