#!/usr/bin/env bash
# Removes the cluster entirely, taking the machine back to roughly the state
# build_cluster.sh found it in.
#
# Usage: ./infrastructure/scripts/destroy_cluster.sh [--keep-packages] [--yes]
#
# This is the counterpart to build_cluster.sh, and it has two depths:
#
#   --keep-packages  resets the cluster so the *playbook can rebuild it*. Packages, Helm,
#                    crictl, the apt repo, the sysctl and modules files, the systemd
#                    drop-ins and the resolved Helm chart cache all stay, because the
#                    rebuild wants them.
#   (default)        removes the cluster *and everything installed to run it*, so the next
#                    build is genuinely a fresh-machine build.
#
# --keep-packages replaces nuke_cluster.sh, which did the same job and was deleted when
# this grew a superset of it: same reset, same Cilium node-local state, same chart cache
# left alone -- plus the state directories nuke never cleared, verified unmounts, and
# containerd stopped before /etc/cni/net.d goes. It also resolves the invoking user's home
# in preflight rather than from $SUDO_USER after the reset, which was #24.
#
# Run it as the login user, not with sudo -- it calls sudo where it needs to. Some of what
# has to go lives in the operator's home (~/.kube, the Helm chart cache under the
# checkout), and a script that already knows who it is does not have to guess the way
# nuke_cluster.sh used to guess at $SUDO_USER.
#
# What it deliberately does NOT remove:
#   Ansible and its  the one thing build_cluster.sh installs that this leaves behind.
#   collections      Removing them would make the next build reinstall Ansible before it
#                    could do anything, and they are not cluster state -- but it does mean
#                    "everything installed to run it" has this one exception, and that
#                    install_ansible.sh and the Galaxy step stay untested by a
#                    destroy/build cycle on a machine that already has them.
#   chrony           an ordinary system time service. The playbook installs it and orders
#                    kubelet behind it; the drop-ins go, chrony stays.
#   docker           never installed by this repo. See the containerd step below -- that
#                    one is shared, and is skipped rather than forced when it is.
#   the NVIDIA       never installed by this repo -- the playbook asserts a driver is
#   driver           present and refuses to run without one, and the GPU Operator's own
#                    driver component is disabled for that reason. Installing one means
#                    owning kernel modules and reboots. A destroyed machine still has a
#                    working `nvidia-smi`.
#   the checkout     git tracks it; only the gitignored chart cache inside it is cleared.
#
# WARNING for anyone editing playbook.yml: the host-tuning half of this script is a
# hand-maintained mirror of what that play writes outside /etc/kubernetes -- the sysctl
# file, the modules-load file, the systemd drop-ins, the fstab edit, the apt source and the
# binaries in /usr/local/bin are all restated here as literals, and nothing keeps the two
# in step.
#
# The GPU stack widens that warning in a way worth stating separately, because it is the
# one part of this machine's configuration the play does not write itself. The GPU
# Operator's toolkit DaemonSet unpacks a toolkit into /usr/local/nvidia and writes a
# containerd drop-in, from *inside a container*, so those paths appear in no Ansible task
# and no `git grep`.
#
# The Operator does revert them: its installer traps SIGTERM and unconfigures containerd on
# the way out. But that needs a graceful pod shutdown, and `kubeadm reset` below is not one.
# The reset log says so directly -- every sandbox on the node fails to stop, and the run
# ends on `[reset] Failed to remove containers` -- so nothing here reverts itself, and this
# script removes those paths by hand.
#
# The verification block at the end is the closest thing to a guard: it asserts the machine
# is actually clean rather than trusting that these steps covered everything.
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
                   the old nuke_cluster.sh, plus the state directories it never cleared.
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
warn() { printf '    \033[1;33mnote:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

kubelet_mounts() { findmnt -rno TARGET | awk '/^\/var\/lib\/kubelet(\/|$)/' | sort -r; }

# ── Preflight ─────────────────────────────────────────────
# Everything that could abort the run is decided here, before anything is destroyed.
# #24 is the shape of the bug this avoids: nuke_cluster.sh resolved the invoking user's
# home *after* `kubeadm reset`, under `set -e`, so a home it cannot resolve exits the
# script halfway through a teardown -- past the reset, before the containerd restart.
step "Preflight"

if [ "$(id -u)" -eq 0 ]; then
  die "run this as the login user, not with sudo -- it calls sudo itself. Running as
    root means guessing whose ~/.kube and whose chart cache to clear."
fi
sudo -v || die "this script needs sudo, on a terminal."

TARGET_USER=$(id -un)
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)
[ -n "$TARGET_HOME" ] || die "cannot resolve the home directory of $TARGET_USER."
info "user $TARGET_USER, home $TARGET_HOME"

# kubeadm reset drives the CRI through crictl. Without it the reset reports success while
# leaving every container running, and everything after this point then deletes the
# configuration needed to find them again. Checked while the node is still intact, which is
# the one moment this failure is cheap.
if [ -d /etc/kubernetes ] || systemctl is-active --quiet kubelet 2>/dev/null; then
  command -v crictl >/dev/null || die "crictl not found, and there is a cluster here to
    reset. kubeadm reset needs it to stop containers; without it the reset is a no-op that
    reports success. The playbook installs it -- see its crictl block."
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
    printf 'containerd, Helm, crictl, the NVIDIA container toolkit the GPU Operator\n'
    printf 'installed, and the host tuning that goes with them. The GPU driver itself\n'
    printf 'is left alone.\n'
  fi
  printf 'Everything in etcd goes with it, and there is no backup step here.\n'
  printf 'Type the hostname (%s) to continue: ' "$(hostname)"
  read -r reply
  [ "$reply" = "$(hostname)" ] || die "not confirmed -- nothing was changed."
fi

# ── Reset the cluster ─────────────────────────────────────
step "kubeadm reset"
if [ -d /etc/kubernetes ] || systemctl is-active --quiet kubelet 2>/dev/null; then
  # Expect a burst of `StopPodSandbox ... DeadlineExceeded` here if the CNI agent is
  # already gone: cilium-cni reads a missing agent socket as "the agent is starting up",
  # retries on a 5s cycle and never beats kubeadm's 2s deadline, so every pod-network
  # sandbox times out. It is bounded at 5 attempts each and the reset completes; on a
  # healthy cluster the teardown is roughly ten times faster.
  sudo kubeadm reset -f
else
  warn "no /etc/kubernetes and kubelet is not running -- nothing to reset"
fi

# kubelet keeps trying to reconcile against an API server that is now gone, which
# re-creates mounts under /var/lib/kubelet while this script is deleting them.
step "Stopping kubelet"
if systemctl list-unit-files kubelet.service >/dev/null 2>&1; then
  sudo systemctl disable --now kubelet 2>/dev/null || true
  info "kubelet stopped and disabled"
else
  warn "no kubelet unit"
fi

# containerd has to go down BEFORE /etc/cni/net.d is removed. containerd watches its CNI
# conf dir with inotify and treats removal of the *directory* as unrecoverable:
#
#   fatal  Failed to run CRI service
#          error="cni network conf monitor error: cni conf dir is removed, stop watching"
#   containerd.service: Main process exited, code=exited, status=1/FAILURE
#
# That is from the first real run of this script, which deleted the directory out from
# under a live containerd and took it down with a failure status mid-teardown.
step "Stopping containerd"
if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
  sudo systemctl stop containerd 2>/dev/null || true
  # Clearing a `failed` state is free and makes the --keep-packages restart deterministic;
  # systemd refuses a start once the start-limit burst is reached.
  sudo systemctl reset-failed containerd 2>/dev/null || true
  info "containerd stopped"
else
  warn "no containerd unit"
fi

# ── Node-local state kubeadm reset leaves behind ──────────
# kubeadm reset explicitly leaves CNI-created interfaces, mounts and anything outside
# /etc/kubernetes alone. All of the below is keyed to the old pod CIDR or the old CA, so
# leaving it turns the next build into a debugging session about x509 errors and stale
# ipcache entries.
step "Cilium node-local state"

# /run/cilium/cgroupv2 is not Cilium state: it is Cilium's automount of the host's unified
# cgroup hierarchy, left in the host mount namespace when the pod died. Dropping it is
# housekeeping; --one-file-system on the rm below is the actual guard that keeps the delete
# out of the live cgroup tree whether or not this umount worked.
sudo umount /run/cilium/cgroupv2 2>/dev/null || true

# cilium_net is cilium_host's veth peer and goes with it. Per-endpoint lxc* veths went with
# their containers during the reset.
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

step "GPU Operator node state"
# Written by the Operator's toolkit DaemonSet from inside a container, not by any task in
# playbook.yml -- see the header. The DaemonSet reverts all of it on a graceful SIGTERM,
# which a `kubeadm reset` never delivers, so on this path it survives.
#
# Cleared even under --keep-packages, unlike the packages themselves: a rebuild re-runs the
# Operator, and it is the *toolkit version* pinned into these files that would be stale. A
# drop-in from a previous Operator naming a BinaryName under an install dir the new one has
# replaced is the GPU equivalent of the stale Cilium BPF maps below -- containerd loads it
# happily and every GPU pod fails at container start.
#
# The drop-in glob is deliberately wider than one filename: the Operator picks the drop-in
# path itself and has changed it between versions, so match what it writes rather than one
# literal. find, not a shell glob -- an unmatched glob is fatal under zsh, which would skip
# this cleanup on exactly the runs where the directory is already clean.
if [ -d /etc/containerd/conf.d ]; then
  sudo find /etc/containerd/conf.d -maxdepth 1 -name '*nvidia*.toml' -delete 2>/dev/null || true
  # Only if this emptied it. rmdir refuses a directory still holding somebody else's
  # drop-in, which is the outcome to want.
  sudo rmdir /etc/containerd/conf.d 2>/dev/null || true
  info "cleared NVIDIA containerd drop-ins"
fi

# The CDI specs the device plugin generates, which is how a GPU actually reaches a pod here:
# containerd 2.x has CDI on by default and the plugin runs with
# DEVICE_LIST_STRATEGY=cdi-annotations,cdi-cri, so the runtime handler is never on the path
# for an ordinary GPU workload -- the spec in /var/run/cdi is. It names device nodes and the
# hook under /usr/local/nvidia that the step below deletes, so leaving it behind leaves a
# spec pointing at a hook that is gone. (/var/run is a symlink to /run, and containerd's
# own `cdi_spec_dirs` spells it /var/run/cdi, so this matches the config rather than the
# shorter path the prose elsewhere uses.)
#
# /run is a tmpfs and so this self-clears on reboot, and a rebuild regenerates the spec
# regardless. It goes anyway: a teardown that has to be followed by a reboot to be complete
# is not the claim this script makes.
#
# A glob rather than filenames, and that is load-bearing rather than defensive: the live
# directory holds `k8s.device-plugin.nvidia.com-gpu.json` AND
# `management.nvidia.com-gpu.yaml` -- two names, two components, even two file extensions.
# Any literal would have missed one.
# Still scoped to *nvidia* rather than clearing the directory, because CDI is a general
# mechanism and another vendor's spec is not ours to delete.
for cdi_dir in /var/run/cdi /etc/cdi; do
  [ -d "$cdi_dir" ] || continue
  sudo find "$cdi_dir" -maxdepth 1 -name '*nvidia*' -delete 2>/dev/null || true
done
info "cleared NVIDIA CDI specs"

# /run/nvidia is a tmpfs-backed runtime directory that also carries the driver-root bind
# mount the Operator sets up; /usr/local/nvidia is the toolkit install dir (toolkit.installDir
# in system-apps/gpu-operator/values.yaml). Neither belongs to the host driver, which lives
# under /usr/lib and /usr/bin and is not touched here.
for d in /run/nvidia /usr/local/nvidia; do
  if [ -e "$d" ]; then
    sudo umount "$d" 2>/dev/null || true
    sudo rm -rf --one-file-system "$d" || true
    if [ -e "$d" ]; then
      warn "$d could not be fully removed -- something under it is still mounted or in use"
    else
      info "removed $d"
    fi
  fi
done

step "Kubernetes state directories"
# kubelet leaves a tmpfs mount under /var/lib/kubelet/pods for every secret and projected
# volume -- sixteen on a modest cluster.
#
# Matched by prefix over every mount, NOT with `findmnt --submounts /var/lib/kubelet`:
# --submounts descends from a mount point, and /var/lib/kubelet is an ordinary directory on
# the root filesystem, so that form matched nothing at all on a node carrying sixteen of
# them. It fails silently, because an empty list is what a clean node looks like too.
#
# Deepest first: projected volumes nest inside pod directories that are themselves mounts.
mapfile -t kubelet_mnts < <(kubelet_mounts)
if [ ${#kubelet_mnts[@]} -gt 0 ]; then
  for mp in "${kubelet_mnts[@]}"; do
    sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
  done
  info "unmounted ${#kubelet_mnts[@]} kubelet volume mounts"
fi

# Checked, not assumed -- and checked BEFORE anything is deleted. All three unmount
# attempts above swallow their errors, and `rm -rf --one-file-system` does not step over a
# surviving mount quietly: it refuses the whole tree.
#
#   $ rm -rf --one-file-system t     # t/pods/x is a tmpfs
#   rm: skipping 't/pods/x', since it's on a different device
#   exit=1                           # and t/, t/pods/ and t/pods/x all survive
#
# Under `set -e` that ends the run at /var/lib/kubelet, six steps into fourteen: the
# kubeconfigs, the chart cache, the packages, the apt source, the binaries, the host tuning
# and the swap restore would all be skipped, leaving a half-torn-down machine and no
# summary of what was missed. That is the failure mode the preflight above exists to
# prevent, so fail the same way -- with the list, before any delete.
remaining_mnts=$(kubelet_mounts)
if [ -n "$remaining_mnts" ]; then
  die "these mounts under /var/lib/kubelet could not be unmounted:
$(printf '        %s\n' $remaining_mnts)
    Nothing has been deleted. Find what is holding them (\`lsof +f -- <path>\`, or a
    container that survived the reset), clear it, and re-run -- this script is idempotent."
fi

for d in /etc/kubernetes /etc/cni/net.d /var/lib/etcd /var/lib/kubelet; do
  if [ -e "$d" ]; then
    # Reported from the result, not from having run the command. With --one-file-system,
    # "removed" can mean "left in place" -- so check.
    sudo rm -rf --one-file-system "$d" || true
    if [ -e "$d" ]; then
      die "$d could not be fully removed -- something under it is on another filesystem
    or still in use. The machine is partially torn down; resolve it and re-run."
    fi
    info "removed $d"
  fi
done

# Run as this user, so ~ is the operator's -- but the playbook's kubeadm post-init copy
# also leaves one under /root if anyone ran `sudo kubectl`. Both are stale the moment the
# CA is gone, and a leftover config turns the next build's first kubectl into an x509 error
# that reads as though the new cluster is broken.
step "kubeconfigs"
sudo rm -rf /root/.kube
rm -rf "$TARGET_HOME/.kube"
info "removed /root/.kube and $TARGET_HOME/.kube"

restart_containerd() {
  if ! systemctl list-unit-files containerd.service >/dev/null 2>&1; then
    warn "containerd is not installed -- nothing to restart"
    return
  fi
  # Distinguished from "not installed", which the unit-file check above already answers.
  # A restart can fail here for reasons this script created -- /etc/cni/net.d is gone, the
  # config is gone, the start-limit burst was hit -- and reporting all of them as "not
  # installed" points the operator at the wrong thing entirely.
  if sudo systemctl restart containerd; then
    info "containerd restarted"
  else
    warn "containerd failed to restart:"
    sudo systemctl status containerd --no-pager -l 2>&1 | sed -n '1,15p' | sed 's/^/        /'
  fi
}

if [ "$KEEP_PACKAGES" -eq 1 ]; then
  step "Restarting containerd"
  restart_containerd
  step "Done (--keep-packages)"
  cat <<EOF
    The cluster is gone and the node is clean, but kubeadm, kubelet, containerd, Helm,
    crictl, the apt repo and the host tuning are all still installed. Rebuild with:
        ./infrastructure/scripts/build_cluster.sh
EOF
  exit 0
fi

# Cleared only on a full destroy -- deliberately below the --keep-packages exit above.
# That flag exists so the play can rebuild, and the play's cache check stats for the exact
# `<name>-<version>.tgz` its Chart.yaml declares, so the cache already invalidates itself
# when a dependency version changes. Wiping it otherwise only makes every rebuild need
# helm.cilium.io reachable. nuke_cluster.sh left it in place for that reason; matching it
# here is what made --keep-packages a strict superset, and let that script be deleted.
#
# On a full destroy it goes: the next build is meant to be a fresh-machine build, and a
# resolved cache pinned to whatever was current when it was written is not that.
step "Helm chart cache in the checkout"
if [ -d "$SYSTEM_APPS" ]; then
  # No `|| true` swallowing the result: a cache left root-owned by a run someone did with
  # sudo fails here, and reporting "cleared" over that is how the next build ends up
  # rendering a stale chart.
  if find "$SYSTEM_APPS" -mindepth 2 -maxdepth 2 \
       \( -name charts -type d -o -name Chart.lock -type f \) -exec rm -rf {} + 2>/dev/null; then
    info "cleared charts/ and Chart.lock under system-apps/"
  else
    warn "could not fully clear the chart cache under $SYSTEM_APPS -- check ownership (a
    run done with sudo leaves it root-owned). The next build may render a stale chart."
  fi
else
  warn "no $SYSTEM_APPS -- nothing to clear"
fi

# ── Packages ──────────────────────────────────────────────
step "Packages"
# The playbook holds these, and apt refuses to remove a held package with a message about
# broken dependencies rather than about the hold.
for pkg in kubelet kubeadm kubectl; do
  sudo apt-mark unhold "$pkg" >/dev/null 2>&1 || true
done

# Matched on the *current* state field, not the desired-state one. dpkg reports a held
# package as "hold ok installed", so testing for "^install ok installed" quietly drops
# exactly the three packages the unhold above just ran for -- and if that unhold failed, it
# drops them silently and the run still reports success over a node that still has kubelet.
installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | awk '$3 == "installed" { found = 1 } END { exit !found }'
}

containerd_kept=0
purge=()
for pkg in kubelet kubeadm kubectl kubernetes-cni; do
  installed "$pkg" && purge+=("$pkg")
done

# containerd is the one package here that is plausibly not ours. Docker's containerd.io and
# Ubuntu's containerd both provide the runtime, and a machine that also runs Docker has one
# for reasons unrelated to this cluster -- purging it would take Docker down as collateral.
# Purge it only when nothing installed depends on it.
#
# --important, so a package that merely Recommends or Suggests containerd does not block
# the purge and get named as a dependant. The difference is not small: for `gpg`, all
# reverse-deps is 16 and important is 10.
#
# sudo, because an unprivileged apt-cache silently drops a sources.list.d file it cannot
# read -- and the play wrote kubernetes.list 0600 until this branch fixed it, so this very
# query emitted "W: Unable to read /etc/apt/sources.list.d/kubernetes.list". A repository
# that disappears for non-root readers is a bad input to a decision this consequential.
#
# The provider names are derived, not restated: `apt-cache showpkg` lists what Provides
# containerd virtually (containerd.io and containerd-stable today), and those appear in the
# rdepends output as headings rather than as real dependants.
#
# awk rather than `grep -v ... || true`: `|| true` makes "the filter errored" look identical
# to "nothing depends on it", and it fails towards purging -- the wrong direction for a
# decision that can take Docker's runtime with it. That reasoning stands on its own; the
# empty alternation `(...|)$` in the first draft of this line is a portability landmine
# (ugrep rejects what GNU grep accepts) rather than a bug that ever fired here, since a
# script gets /usr/bin/grep, which is GNU. An earlier version of this comment claimed
# otherwise, from a `grep --version` run in an interactive shell that had a `grep` function
# in front of the binary -- see the retraction note below the swap step.
if installed containerd; then
  # Guarded for the same reason as the autoremove hint below (#58) -- these are also
  # unguarded assignments sitting after the destructive phase, and an apt-cache that
  # cannot run would end the teardown here with no message -- but guarded the other way.
  # A `|| true` would leave both variables empty, which reads as "nothing depends on
  # containerd" and purges it, taking Docker's runtime with it. The hint below may fail
  # towards silence; this may not fail towards purging, so it fails towards `die`.
  # Opens with what failed rather than with apt, because the pipeline includes `sudo`: a
  # lapsed credential lands here too, and the preflight's `sudo -v` is what covers that.
  apt_unreadable="could not read apt's dependency data, so whether purging containerd would
    take another runtime's dependency with it is unknown -- and this script does not guess
    in that direction. Nothing has been purged; the cluster and its state directories are
    already gone. \`sudo apt-get update\` names a sources file apt cannot parse, and
    \`apt-cache rdepends\` exits 100 on a package apt no longer knows -- which is what an
    installed containerd from a since-removed repo looks like. Fix that and re-run -- this
    script is idempotent."
  provides=$(apt-cache showpkg containerd 2>/dev/null \
    | sed -n '/Reverse Provides:/,$p' | awk 'NR > 1 && NF { print $1 }' | sort -u) \
    || die "$apt_unreadable"
  candidates=$(sudo apt-cache rdepends --installed --important containerd 2>/dev/null \
    | tail -n +3 | tr -d ' |' | awk 'NF' | sort -u) \
    || die "$apt_unreadable"
  # A virtual provider name is not a dependant that can break, and neither is containerd
  # itself; everything else only counts if it is really installed.
  real_dependants=""
  for cand in $candidates; do
    [ "$cand" = containerd ] && continue
    printf '%s\n' $provides | grep -qx "$cand" && continue
    installed "$cand" && real_dependants="$real_dependants $cand"
  done
  if [ -z "${real_dependants// /}" ]; then
    purge+=(containerd)
  else
    # Recorded, not just printed. The verification block at the end asserts containerd is
    # gone, and this is the one path on which its still being here is correct -- so a
    # fully successful teardown on a Docker box would otherwise end with
    # "STILL HERE containerd" and exit 1, failing in exactly the scenario this branch
    # exists to handle.
    containerd_kept=1
    warn "containerd is left installed -- these installed packages depend on it:$real_dependants"
  fi
fi

if [ ${#purge[@]} -gt 0 ]; then
  info "purging: ${purge[*]}"
  sudo apt-get purge -y "${purge[@]}"
else
  warn "no cluster packages installed"
fi

# Deliberately NO `apt-get autoremove`. It is not scoped to what this script purged -- it
# removes everything apt currently considers orphaned, whenever it was orphaned and by whom.
# The first real run proved the point: alongside containerd's `runc` it swept up 13 old
# kernel packages, `docker-ce-rootless-extras`, `pigz` and a stale `nvidia-firmware-595` --
# on a machine whose entire purpose is serving models on a GPU. Nothing broke that time (the
# firmware was a superseded version and both live kernels survived), but a teardown script
# does not get to make that call for the operator.
#
# Parsing `apt-get -s` output is not a stable interface, so this is advisory only: a format
# change makes it silently report 0. Acceptable for a hint, not for a decision.
#
# Guarded, because an assignment from a command substitution adopts that command's status
# and `set -e` acts on it (#58):
#
#   $ bash -c 'set -euo pipefail; x=$(false); echo REACHED'; echo "rc=$?"
#   rc=1                                    # REACHED is not printed
#
# Under `pipefail` an apt-get that exits non-zero ended the run on this line. What does that
# is a sources file apt cannot *parse* -- measured, each returning 100: a malformed one-line
# entry, and a deb822 stanza missing Types or Suites/Components. A source apt merely cannot
# *fetch* returns 0, so "no Release file" is the wrong guess (an earlier version of this
# comment said exactly that): a dead URI, a file: repo that is not there and an unknown
# option all exit 0 on both this command and the apt-cache reads above. Not hypothetical
# here -- the play writes kubernetes.list and the step below removes it.
#
# Also NOT the dpkg lock, which is the other obvious guess: the preflight refuses to run as
# root, and unprivileged `apt-get -s` says so itself -- "Keep also in mind that locking is
# deactivated".
#
# That is #24's shape past the point a preflight can help: the packages are already gone,
# and containerd's state, /opt/cni, the apt source, the binaries, the host tuning, the swap
# restore and the verification block all sit below it. An advisory hint does not get to end
# a teardown, and this one ended it without a word of its own.
#
# The `|| true` sits next to the command that can fail. Note which position is the broken
# one: inside the *substitution*, at the end of the pipeline, awk's END block has already
# run and printed its own 0, so `orphans` comes back as two lines that `[` refuses --
#
#   $ orphans=$(false | awk '/^Remv /{n++} END{print n+0}' || echo 0)
#   $ [ "$orphans" -gt 0 ]
#   bash: [: 0
#   0: integer expected
#
# -- reporting "0 orphaned" on stdout and a bash error on stderr, i.e. wrong in exactly the
# runs it was added for. `...) || echo 0`, genuinely *after* the substitution, does work:
# awk's 0 is already in the variable and the echo only litters stdout with a stray 0. So
# #58's literal suggestion is untidy rather than broken; this form is neither.
orphans=$( { apt-get -s autoremove 2>/dev/null || true; } \
           | awk '/^Remv /{n++} END{print n+0}' )
if [ "$orphans" -gt 0 ]; then
  info "$orphans package(s) are now orphaned -- NOT removed. Review and remove them with:"
  info "    apt-get -s autoremove   # see the list first"
  info "    sudo apt autoremove"
fi

# containerd's own state survives `apt purge` -- the package does not own
# /var/lib/containerd -- and it holds every image the cluster pulled plus the bolt database
# whose name reservations are what recover_apiserver.sh exists to clear. Removed only when
# the package went with it; on a Docker box that directory is Docker's too.
if printf '%s\n' "${purge[@]+"${purge[@]}"}" | grep -qx containerd; then
  sudo rm -rf --one-file-system /var/lib/containerd /etc/containerd
  info "removed /var/lib/containerd and /etc/containerd"
fi

# kubernetes-cni owns the reference plugins under /opt/cni/bin, but the directory
# accumulates binaries from every CNI the node has ever run -- this one still held calico's
# from before Cilium. Purging the package leaves those.
#
# `if` rather than `[ -d ] && { ... }` for legibility, not for correctness: `set -e`
# exempts a command that fails inside an AND-list, so the bare form does not end the run
# mid-script. It only bites as the last statement of a script or function, where the
# list's non-zero status becomes the enclosing status. Neither applies here.
if [ -d /opt/cni ]; then
  sudo rm -rf /opt/cni
  info "removed /opt/cni"
fi

step "apt repository"
sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg
info "removed the Kubernetes apt list and keyring"

# ── Binaries the playbook installed by hand ───────────────
# `if` for the same legibility reason as /opt/cni above. An earlier revision of this
# comment claimed the bare `[ -e ] && { ... }` form ended the run when crictl was already
# absent -- that was asserted from reasoning and is wrong: `set -e` exempts a failing
# command inside an AND-list, and this loop is not the script's last statement either way.
# The rewrite was worth keeping, the diagnosis was not.
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
info "removed /etc/modules-load.d/k8s.conf and /etc/sysctl.d/k8s.conf"
# The sysctls stay applied in the running kernel until a reboot; --system re-reads what is
# left on disk, which puts ip_forward and the bridge-nf keys back to whatever the rest of
# the configuration says. Reported separately from the deletion above, which succeeded
# whether or not this does.
if sudo sysctl --system >/dev/null 2>&1; then
  info "reloaded sysctl from the remaining configuration"
else
  warn "sysctl --system failed; the k8s values stay applied in the running kernel until reboot"
fi

# The drop-ins go; chrony itself stays. Ordering containerd behind time-sync.target is only
# meaningful while containerd is a Kubernetes runtime.
for unit in kubelet containerd; do
  sudo rm -f "/etc/systemd/system/$unit.service.d/10-time-sync.conf"
  sudo rmdir "/etc/systemd/system/$unit.service.d" 2>/dev/null || true
done
sudo systemctl daemon-reload
info "removed the time-sync drop-ins (chrony itself is left installed)"

# The playbook comments out swap in fstab and runs swapoff. Both are reversible and
# cluster-specific -- kubelet is the only thing on the machine that cares.
#
# `[^#[:space:]]` for the first character, not `[^#]`. The playbook writes `#` directly
# against the entry (`replace: '#\1'`), while a human commenting a line out almost always
# writes `# `. The looser pattern matched that space too and re-enabled a swap device the
# operator had disabled on purpose -- so the guard the comment claimed did not exist. Still
# a heuristic, but now one that matches what it says.
step "Swap"
if [ -f /etc/fstab ] && grep -qE '^#[^#[:space:]].*[[:space:]]swap[[:space:]]' /etc/fstab; then
  sudo sed -i -E 's/^#([^#[:space:]].*[[:space:]]swap[[:space:]].*)$/\1/' /etc/fstab
  sudo swapon -a 2>/dev/null || true
  info "re-enabled swap in /etc/fstab"
else
  warn "no playbook-commented swap entry in /etc/fstab (a '# ' prefixed line is left alone)"
fi

# ── Verification ──────────────────────────────────────────
# build_cluster.sh argues that a green run is not the same claim as a working result; the
# same applies in reverse. Every step above reports what it did, which is not the same as
# the machine being clean -- and because the host-tuning half of this script is a
# hand-maintained mirror of playbook.yml (see the header), the thing most likely to go wrong
# is a step that does not exist yet for a file the play has started writing. Asserting the
# end state is the only thing here that could catch that.
step "Verifying the machine is clean"
clean=1
gone() {
  if [ -e "$1" ]; then printf '    %-12s %s\n' "STILL HERE" "$1"; clean=0
  else printf '    %-12s %s\n' "gone" "$1"; fi
}
absent() {
  if command -v "$1" >/dev/null; then
    printf '    %-12s %s (%s)\n' "STILL HERE" "$1" "$(command -v "$1")"; clean=0
  else printf '    %-12s %s\n' "gone" "$1"; fi
}
binaries=(kubeadm kubelet kubectl helm crictl)
paths=(/etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d /opt/cni
       /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf
       /etc/apt/sources.list.d/kubernetes.list
       /etc/apt/keyrings/kubernetes-apt-keyring.gpg
       /etc/systemd/system/kubelet.service.d/10-time-sync.conf
       /etc/systemd/system/containerd.service.d/10-time-sync.conf
       /run/nvidia /usr/local/nvidia
       "$TARGET_HOME/.kube")
if [ "$containerd_kept" -eq 0 ]; then
  binaries+=(containerd)
  paths+=(/var/lib/containerd /etc/containerd)
else
  info "containerd was deliberately left installed, so it and its state are not checked"
fi
for b in "${binaries[@]}"; do absent "$b"; done
for d in "${paths[@]}"; do gone "$d"; done

# /root is 0700, so a plain `[ -e ]` as the login user reports "gone" for a directory that
# is still there -- a false pass on exactly the leftover the header calls out as turning
# the next build's first kubectl into an x509 mystery.
if sudo test -e /root/.kube; then
  printf '    %-12s %s\n' "STILL HERE" "/root/.kube"; clean=0
else
  printf '    %-12s %s\n' "gone" "/root/.kube"
fi
if ip -br link show 2>/dev/null | grep -q '^cilium'; then
  printf '    %-12s %s\n' "STILL HERE" "cilium network interfaces"; clean=0
fi

if [ "$clean" -ne 1 ]; then
  die "the teardown ran but the machine is not clean -- see STILL HERE above. If one of
    those is something playbook.yml started writing and this script does not know about,
    that is the mirror drifting; add the matching step here."
fi

step "Done"
cat <<EOF
    The cluster and everything installed to run it are gone, and verified gone.

    Left alone on purpose: Ansible and its collections, chrony, Docker (if present), and
    the checkout itself. Kernel modules loaded this boot (overlay, br_netfilter) stay
    loaded until a reboot; nothing reloads them now that /etc/modules-load.d/k8s.conf is
    gone.

    Rebuild with:
        ./infrastructure/scripts/build_cluster.sh
EOF
