#!/usr/bin/env bash
# Tears a single-node cluster down far enough that the playbook can rebuild it.
#
# Usage: sudo ./nuke_cluster.sh
#
# set -e matters here: every rm below assumes the reset above it succeeded. Without it a
# failed `kubeadm reset` -- a CRI it cannot reach, a mount it cannot release -- is
# followed by the deletion of /etc/kubernetes anyway, which throws away the PKI and the
# static pod manifests needed to diagnose it and leaves a node that neither runs nor
# rebuilds cleanly.
set -euo pipefail

# kubeadm reset drives the CRI through the crictl binary, so a missing crictl means the
# reset leaves every container running while reporting success. Checked before anything
# is destroyed rather than after: this is the one failure that is cheap while the node is
# still intact. See README.md for the cri-tools install.
command -v crictl >/dev/null || {
  echo "crictl not found -- kubeadm reset needs it to stop containers. See README.md." >&2
  exit 1
}

kubeadm reset -f

rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes

# kubeadm reset explicitly leaves CNI-created interfaces, mounts and any state outside
# /etc/kubernetes alone, so Cilium's node-local state outlives the nuke: cilium_host
# keeps the old router IP (and its /24 route), cilium_vxlan the old tunnel,
# /var/run/cilium/state the endpoint state, and the pinned BPF maps the ipcache and
# service entries -- all keyed to the old pod CIDR.
#
# That was harmless while the pod CIDR never changed. It is not once it does. The agent
# is supposed to notice stale state and discard it; clearing it outright means not
# depending on that on the one run where rollback is hardest.

# /run/cilium/cgroupv2 is NOT Cilium state -- it is Cilium's automount of the host's
# unified cgroup hierarchy (cgroup.autoMount.enabled), left behind in the host mount
# namespace when the pod died, and kubeadm reset does not unmount it. Since /var/run is
# a symlink to /run, a plain recursive delete of /var/run/cilium walks into the live
# cgroup root: EPERM on every control file, and -- because kubeadm reset has just
# stopped every container -- successful rmdir on the now-empty cgroups behind
# kubepods.slice and friends.
#
# Drop the stale mount, which is worth cleaning up in its own right; the mount-cgroup
# init container recreates it on the next install. This is housekeeping, NOT the guard:
# it is best-effort by design (EBUSY, stacked mounts from repeated init-container runs),
# and the path is the chart default for cgroup.hostRoot, so overriding that key in
# ../k8s-ansible/system-apps/cilium/values.yaml would silently make this a no-op. The
# guard is --one-file-system on the rm below.
umount /run/cilium/cgroupv2 2>/dev/null || true

# cilium_net is cilium_host's veth peer and goes with it. Per-endpoint lxc* veths go
# with their containers.
ip link del cilium_host 2>/dev/null || true
ip link del cilium_vxlan 2>/dev/null || true

# --one-file-system is what actually keeps this delete out of the cgroup hierarchy: it
# skips any directory on a different filesystem from the argument, so the recursion
# stops at a mount boundary whether or not the umount above worked and whatever
# cgroup.hostRoot points at. /run/cilium is tmpfs (dev 29) and /run/cilium/cgroupv2 is
# cgroup2fs (dev 30), so the boundary is real. GNU coreutils only; this box has 9.7.
#
# /var/lib/cilium does not exist on this node today (endpoint state lives under
# /var/run/cilium/state); it is listed because Cilium uses it when state-dir is moved
# off tmpfs, and the rm is a no-op when absent.
rm -rf --one-file-system /var/run/cilium /var/lib/cilium

# bpffs is its own mount, so nothing above touches the pinned maps -- cilium_ipcache,
# cilium_lxc, cilium_lb4_services_v2, cilium_tunnel_map. Cilium itself only clears them
# via the clean-cilium-state init container, which needs CLEAN_CILIUM_STATE, and the
# bootstrap install does not set it. Without this the agent comes up on the new pool
# reading maps still full of 10.0.0.0/24.
#
# find, not a `cilium_*` glob: under zsh an unmatched glob is a fatal error for the
# command rather than a literal passed through as it is in bash, so the cleanup would be
# skipped on exactly the runs where the directory is already clean. The shebang settles
# that for running this as a program, but naming an interpreter on the command line
# overrides it, so `sudo zsh nuke_cluster.sh` still reaches zsh. Narrow, but free to
# avoid.
find /sys/fs/bpf/tc/globals -maxdepth 1 -name 'cilium_*' -exec rm -rf {} + 2>/dev/null || true
rm -rf /sys/fs/bpf/cilium

# Run as root via sudo, so ~ is /root -- that misses the invoking user's config,
# the one the playbook installs. Both are stale after a nuke: root's if the
# operator did the kubeadm post-init copy so `sudo kubectl` works, the user's
# from playbook.yml. Drop both, otherwise a rebuild yields x509 errors against
# the new CA that look unrelated to the reset.
NUKE_USER=${SUDO_USER:-$(id -un)}
# `|| true` so an unresolvable user reaches the `:?` below with its own message rather
# than exiting on getent's status under `set -o pipefail`.
NUKE_HOME=$(getent passwd "$NUKE_USER" | cut -d: -f6 || true)
rm -rf /root/.kube
rm -rf "${NUKE_HOME:?unable to resolve home for $NUKE_USER}/.kube"

systemctl restart containerd

crictl ps