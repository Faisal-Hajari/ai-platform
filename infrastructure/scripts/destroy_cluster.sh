#!/usr/bin/env bash
# Removes the cluster entirely, taking the machine back to roughly the state
# build_cluster.sh found it in.
#
# Usage: ./infrastructure/scripts/destroy_cluster.sh [--keep-packages] [--yes]
#
# This is the counterpart to build_cluster.sh, and a strictly bigger hammer than
# nuke_cluster.sh. The difference is the intent:
#
#   nuke_cluster.sh     resets the cluster so the *playbook can rebuild it*. Packages,
#                       Helm, crictl, the apt repo, the sysctl and modules files and the
#                       systemd drop-ins all stay, because the rebuild wants them.
#   destroy_cluster.sh  removes the cluster *and everything installed to run it*, so the
#                       next build is genuinely a fresh-machine build.
#
# Run it as the login user, not with sudo -- it calls sudo where it needs to. The reason
# is the same one that makes nuke_cluster.sh guess at $SUDO_USER: some of what has to go
# lives in the operator's home (~/.kube, and the Helm chart cache under the checkout),
# and a script that already knows who it is does not have to guess.
#
# What it deliberately does NOT remove, because none of it is the cluster's:
#   chrony        an ordinary system time service. The playbook installs it and orders
#                 kubelet behind it; the drop-ins go, chrony stays.
#   docker        never installed by this repo. See the containerd step below -- that
#                 one is shared, and is skipped rather than forced when it is.
#   the checkout  git tracks it; only the gitignored chart cache inside it is cleared.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SYSTEM_APPS="$REPO_ROOT/infrastructure/k8s-ansible/system-apps"

KEEP_PACKAGES=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Removes the Kubernetes cluster and everything installed to run it.

  ./infrastructure/scripts/destroy_cluster.sh [options]

Options:
  --keep-packages  Reset the cluster and clear node state, but leave the packages,
                   Helm, crictl, the apt repo and the host tuning in place. Roughly
                   nuke_cluster.sh plus the state directories it does not touch.
  -y, --yes        Do not ask for confirmation.
  -h, --help       This message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-packages) KEEP_PACKAGES=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33mskip:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────
# Everything that could abort the run is decided here, before anything is destroyed.
# #24 is the shape of the bug this avoids: nuke_cluster.sh resolves the invoking user's
# home *after* `kubeadm reset`, under `set -e`, so a home it cannot resolve exits the
# script halfway through a teardown -- past the reset, before the containerd restart.
step "Preflight"

if [ "$(id -u)" -eq 0 ]; then
  die "run this as the login user, not with sudo -- it calls sudo itself. Running as
    root means guessing whose ~/.kube and whose chart cache to clear."
fi
sudo -v || die "this script needs sudo."

TARGET_USER=$(id -un)
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)
[ -n "$TARGET_HOME" ] || die "cannot resolve the home directory of $TARGET_USER."
info "user $TARGET_USER, home $TARGET_HOME"

# kubeadm reset drives the CRI through crictl. Without it the reset reports success
# while leaving every container running, and everything after this point then deletes
# the configuration needed to find them again. Checked while the node is still intact,
# which is the one moment this failure is cheap.
if [ -d /etc/kubernetes ] || systemctl is-active --quiet kubelet 2>/dev/null; then
  command -v crictl >/dev/null || die "crictl not found, and there is a cluster here to
    reset. kubeadm reset needs it to stop containers; without it the reset is a no-op
    that reports success. Install it with build_cluster.sh, or see README.md."
  command -v kubeadm >/dev/null || die "kubeadm not found, but /etc/kubernetes exists.
    Removing the state without resetting leaves containers running and mounts held --
    reinstall kubeadm (\`sudo apt install kubeadm\`) and re-run."
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '\n'
  if [ "$KEEP_PACKAGES" -eq 1 ]; then
    printf 'This will DESTROY the cluster on %s and clear all node-local state.\n' "$(hostname)"
  else
    printf 'This will DESTROY the cluster on %s and REMOVE kubeadm/kubelet/kubectl,\n' "$(hostname)"
    printf 'containerd, Helm, crictl and the host tuning that goes with them.\n'
  fi
  printf 'Everything in etcd goes with it, and there is no backup step here.\n'
  printf 'Type the hostname (%s) to continue: ' "$(hostname)"
  read -r reply
  [ "$reply" = "$(hostname)" ] || die "not confirmed -- nothing was changed."
fi

# ── Reset the cluster ─────────────────────────────────────
step "kubeadm reset"
if [ -d /etc/kubernetes ] || systemctl is-active --quiet kubelet 2>/dev/null; then
  sudo kubeadm reset -f
else
  warn "no /etc/kubernetes and kubelet is not running -- nothing to reset"
fi

# kubelet keeps running and keeps trying to reconcile against an API server that is now
# gone, which re-creates mounts under /var/lib/kubelet while this script is deleting
# them. Stop it before touching that directory rather than after.
step "Stopping kubelet"
if systemctl list-unit-files kubelet.service >/dev/null 2>&1; then
  sudo systemctl disable --now kubelet 2>/dev/null || true
  info "kubelet stopped and disabled"
else
  warn "no kubelet unit"
fi

# containerd has to go down BEFORE /etc/cni/net.d is removed, and this is not tidiness.
# containerd watches its CNI conf dir with inotify, and treats removal of the *directory*
# as unrecoverable:
#
#   error  failed to reload cni configuration after receiving fs change event
#          (REMOVE "/etc/cni/net.d/05-cilium.conflist")
#   fatal  Failed to run CRI service
#          error="cni network conf monitor error: cni conf dir is removed, stop watching"
#   containerd.service: Main process exited, code=exited, status=1/FAILURE
#
# That is from the first real run of this script, which deleted the directory out from
# under a live containerd and took it down with a failure status mid-teardown. The full
# purge below papered over it -- the package was going anyway -- but --keep-packages did
# the rest of its work against a dead runtime and left the unit failed until the restart
# at the end. Stop it deliberately instead of killing it by side effect.
step "Stopping containerd"
if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
  sudo systemctl stop containerd 2>/dev/null || true
  # The run that discovered this left the unit in `failed`, where a later `start` is still
  # refused if systemd's start-limit burst was reached. Clearing it is free and makes the
  # --keep-packages restart below deterministic.
  sudo systemctl reset-failed containerd 2>/dev/null || true
  info "containerd stopped"
else
  warn "no containerd unit"
fi

# ── Node-local state kubeadm reset leaves behind ──────────
# kubeadm reset explicitly leaves CNI-created interfaces, mounts and anything outside
# /etc/kubernetes alone. All of the below is keyed to the old pod CIDR or the old CA, so
# leaving it turns the next build into a debugging session about x509 errors and stale
# ipcache entries. This block is nuke_cluster.sh's, and the reasoning there is worth
# reading -- it is summarised rather than repeated here.
step "Cilium node-local state"

# /run/cilium/cgroupv2 is not Cilium state: it is Cilium's automount of the host's
# unified cgroup hierarchy, left in the host mount namespace when the pod died. Dropping
# it is housekeeping; --one-file-system on the rm below is the actual guard that keeps
# the delete out of the live cgroup tree whether or not this umount worked.
sudo umount /run/cilium/cgroupv2 2>/dev/null || true

# cilium_net is cilium_host's veth peer and goes with it. Per-endpoint lxc* veths went
# with their containers during the reset.
for link in cilium_host cilium_vxlan; do
  sudo ip link del "$link" 2>/dev/null && info "removed link $link" || true
done

sudo rm -rf --one-file-system /var/run/cilium /var/lib/cilium

# bpffs is its own mount, so nothing above touches the pinned maps -- cilium_ipcache,
# cilium_lxc, cilium_lb4_services_v2, cilium_tunnel_map. Cilium only clears them via the
# clean-cilium-state init container, which the bootstrap install does not enable, so
# without this the next agent comes up reading maps still full of the old pool.
#
# find rather than a `cilium_*` glob: an unmatched glob is fatal under zsh, so
# `sudo zsh destroy_cluster.sh` would skip the cleanup on exactly the runs where the
# directory is already clean.
sudo find /sys/fs/bpf/tc/globals -maxdepth 1 -name 'cilium_*' -exec rm -rf {} + 2>/dev/null || true
sudo rm -rf /sys/fs/bpf/cilium
info "cilium state, links and pinned BPF maps cleared"

step "Kubernetes state directories"
# kubelet leaves tmpfs mounts under /var/lib/kubelet/pods for every secret and projected
# volume -- dozens on a live cluster. `rm -rf` walks into them and reports EBUSY per
# directory; --one-file-system stops at each boundary and silently leaves them. Neither
# actually clears them, so unmount first. Deepest first, because projected volumes nest
# inside the pod directories that also carry mounts.
#
# Matched by prefix over every mount, NOT with `findmnt --submounts /var/lib/kubelet`:
# --submounts descends from a mount point, and /var/lib/kubelet is an ordinary directory
# on the root filesystem, so that form matched nothing at all on a node carrying sixteen
# of these. It fails silently -- an empty list is exactly what a clean node looks like --
# which is the whole reason it is worth spelling out here.
#
# sort -r puts the deepest paths first: projected volumes nest inside pod directories that
# are themselves mount points.
mapfile -t kubelet_mounts < <(findmnt -rno TARGET | awk '/^\/var\/lib\/kubelet(\/|$)/' | sort -r)
if [ ${#kubelet_mounts[@]} -gt 0 ]; then
  for mp in "${kubelet_mounts[@]}"; do
    # Lazy unmount as the fallback rather than the first move: a plain umount that fails
    # says something still has the mount open, and -l detaches it anyway so the delete
    # below can proceed. Neither is allowed to abort the teardown.
    sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
  done
  info "unmounted ${#kubelet_mounts[@]} kubelet volume mounts"
fi

for d in /etc/kubernetes /etc/cni/net.d /var/lib/etcd /var/lib/kubelet; do
  if [ -e "$d" ]; then
    sudo rm -rf --one-file-system "$d"
    info "removed $d"
  fi
done

# Run as this user, so ~ is the operator's -- but the playbook's kubeadm post-init copy
# also leaves one under /root if anyone ran `sudo kubectl`. Both are stale the moment the
# CA is gone, and a leftover config is what turns the next build's first kubectl into an
# x509 error that reads as though the new cluster is broken.
step "kubeconfigs"
sudo rm -rf /root/.kube
rm -rf "$TARGET_HOME/.kube"
info "removed /root/.kube and $TARGET_HOME/.kube"

# Gitignored `helm dependency update` output. Not source, and pinned to the chart version
# that was current when it was resolved -- clearing it is what makes the next build fetch
# the dependency Chart.yaml actually declares.
step "Helm chart cache in the checkout"
if [ -d "$SYSTEM_APPS" ]; then
  find "$SYSTEM_APPS" -mindepth 2 -maxdepth 2 \
    \( -name charts -type d -o -name Chart.lock -type f \) -exec rm -rf {} + 2>/dev/null || true
  info "cleared charts/ and Chart.lock under system-apps/"
else
  warn "no $SYSTEM_APPS -- nothing to clear"
fi

if [ "$KEEP_PACKAGES" -eq 1 ]; then
  step "Restarting containerd"
  sudo systemctl restart containerd 2>/dev/null || warn "containerd is not installed"
  step "Done (--keep-packages)"
  cat <<EOF
    The cluster is gone and the node is clean, but kubeadm, kubelet, containerd, Helm,
    crictl, the apt repo and the host tuning are all still installed. Rebuild with:
        ./infrastructure/scripts/build_cluster.sh
EOF
  exit 0
fi

# ── Packages ──────────────────────────────────────────────
step "Packages"
# The playbook holds these, and apt refuses to remove a held package with a message about
# broken dependencies rather than about the hold. Unhold before purging.
for pkg in kubelet kubeadm kubectl; do
  sudo apt-mark unhold "$pkg" >/dev/null 2>&1 || true
done

# Matched on the *current* state field, not on the desired-state one. dpkg reports a held
# package as "hold ok installed", so testing for "^install ok installed" quietly drops
# exactly the three packages the unhold above just ran for -- and if that unhold failed,
# it drops them silently and the run still reports success over a node that still has
# kubelet. The dry run of this script did precisely that.
installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | awk '$3 == "installed" { found = 1 } END { exit !found }'
}

purge=()
for pkg in kubelet kubeadm kubectl kubernetes-cni; do
  installed "$pkg" && purge+=("$pkg")
done

# containerd is the one package here that is plausibly not ours. Docker's containerd.io
# and Ubuntu's containerd both provide the runtime, and a machine that also runs Docker
# has one of them for reasons that have nothing to do with this cluster -- purging it
# would take Docker down as collateral. Purge it only when nothing installed depends on
# it. `apt-cache rdepends --installed` names the package itself and its virtual provides,
# so filter those out before deciding.
#
# awk rather than `grep -v ... || true`, and that is not a style choice. This decision is
# the difference between leaving Docker alone and purging the runtime underneath it, and
# `|| true` makes "the filter errored" indistinguishable from "nothing depends on it" --
# it fails towards purging. Not hypothetical: Ubuntu 26.04 ships ugrep as /usr/bin/grep,
# and ugrep rejects the empty alternation `(...|)$` that GNU grep accepts, so the first
# draft of this line errored and reported no dependants on a box that had some. awk exits
# 0 on an empty result, so nothing has to be swallowed to get one.
if installed containerd; then
  dependants=$(apt-cache rdepends --installed containerd 2>/dev/null | tail -n +3 \
    | tr -d ' |' \
    | awk 'NF && $0 != "containerd" && $0 != "containerd.io" && $0 != "containerd-stable"' \
    | sort -u)
  if [ -z "$dependants" ]; then
    purge+=(containerd)
  else
    warn "containerd is left installed -- these installed packages depend on it: $(echo "$dependants" | tr '\n' ' ')"
  fi
fi

if [ ${#purge[@]} -gt 0 ]; then
  info "purging: ${purge[*]}"
  sudo apt-get purge -y "${purge[@]}"
else
  warn "no cluster packages installed"
fi

# Deliberately NO `apt-get autoremove`. It is not scoped to what this script purged --
# it removes everything apt currently considers orphaned, whenever it was orphaned and by
# whom. The first real run of this script proved the point: alongside containerd's `runc`
# it swept up 13 old kernel packages, `docker-ce-rootless-extras`, `pigz` and a stale
# `nvidia-firmware-595` -- on a machine whose entire purpose is serving models on a GPU.
# Nothing broke that time (the firmware was an superseded version and both live kernels
# survived), but a teardown script does not get to make that call on the operator's
# behalf. Report the count and let them decide.
orphans=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{n++} END{print n+0}')
if [ "$orphans" -gt 0 ]; then
  info "$orphans package(s) are now orphaned -- NOT removed. Review and remove them with:"
  info "    apt-get -s autoremove   # see the list first"
  info "    sudo apt autoremove"
fi

# containerd's own state survives `apt purge` -- the package does not own /var/lib/containerd
# -- and it holds every image the cluster pulled plus the bolt database whose name
# reservations are what recover_apiserver.sh exists to clear. Removed only when the
# package went with it; on a Docker box that directory is Docker's too.
if printf '%s\n' "${purge[@]+"${purge[@]}"}" | grep -qx containerd; then
  sudo rm -rf --one-file-system /var/lib/containerd /etc/containerd
  info "removed /var/lib/containerd and /etc/containerd"
fi

# kubernetes-cni owns the reference plugins under /opt/cni/bin, but the directory
# accumulates binaries from every CNI the node has ever run -- this one still holds
# calico's from before Cilium. Purging the package leaves those, so clear the directory
# rather than trusting dpkg to have known about its contents.
# `if` for the same `set -e` reason as the loop below: a bare `[ -d ] && { ... }` is a
# statement whose status is the test's, so an already-absent /opt/cni would end the run.
if [ -d /opt/cni ]; then
  sudo rm -rf /opt/cni
  info "removed /opt/cni"
fi

step "apt repository"
sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg
info "removed the Kubernetes apt list and keyring"

# ── Binaries the playbook installed by hand ───────────────
#
# `if`, not `[ -e "$bin" ] && { ... }`. Under `set -e` the exit status of a for loop is
# that of its last command, so an absent crictl -- the last iteration -- made the loop
# return 1 and took the whole script down here, silently skipping every step below.
step "Helm and crictl"
for bin in /usr/local/bin/helm /usr/local/bin/crictl; do
  if [ -e "$bin" ]; then
    sudo rm -f "$bin"
    info "removed $bin"
  fi
done

# ── Host tuning ───────────────────────────────────────────
step "Host tuning"
sudo rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf
# The sysctls stay applied in the running kernel until a reboot; --system re-reads what is
# left on disk, which puts ip_forward and the bridge-nf keys back to whatever the rest of
# the configuration says. Quiet because it prints every file it reads.
sudo sysctl --system >/dev/null 2>&1 || true
info "removed /etc/modules-load.d/k8s.conf and /etc/sysctl.d/k8s.conf"

# The drop-ins go; chrony itself stays. Ordering containerd behind time-sync.target is
# only meaningful while containerd is a Kubernetes runtime, and a drop-in directory left
# behind for a purged unit is the kind of thing that outlives its reason.
for unit in kubelet containerd; do
  sudo rm -f "/etc/systemd/system/$unit.service.d/10-time-sync.conf"
  sudo rmdir "/etc/systemd/system/$unit.service.d" 2>/dev/null || true
done
sudo systemctl daemon-reload
info "removed the time-sync drop-ins (chrony itself is left installed)"

# The playbook comments out swap in fstab and runs swapoff. Both are reversible and both
# are cluster-specific -- kubelet is the only thing on the machine that cares -- so put
# them back. Matched on the exact comment shape the playbook writes (`#` prefixed to a
# line whose third field is `swap`), so a swap line the operator commented out for their
# own reasons is not silently re-enabled.
step "Swap"
if [ -f /etc/fstab ] && grep -qE '^#[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
  sudo sed -i -E 's/^#([^#].*[[:space:]]swap[[:space:]].*)$/\1/' /etc/fstab
  sudo swapon -a 2>/dev/null || true
  info "re-enabled swap in /etc/fstab"
else
  warn "no commented-out swap entry in /etc/fstab"
fi

step "Done"
cat <<EOF
    The cluster and everything installed to run it are gone.

    Left alone on purpose: chrony, Docker (if present), and the checkout itself.
    Kernel modules loaded this boot (overlay, br_netfilter) stay loaded until a reboot;
    nothing reloads them now that /etc/modules-load.d/k8s.conf is gone.

    Rebuild with:
        ./infrastructure/scripts/build_cluster.sh
EOF
