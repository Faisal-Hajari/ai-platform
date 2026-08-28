# you might need to install crictl
# VERSION="v1.31.1"
# wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
# sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
# rm -f crictl-$VERSION-linux-amd64.tar.gz

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
# a symlink to /run, deleting /var/run/cilium without this would recurse into the live
# cgroup root: EPERM on every control file, and -- because kubeadm reset has just
# stopped every container -- successful rmdir on the now-empty cgroups behind
# kubepods.slice and friends. Unmount first; the mount-cgroup init container recreates
# it on the next install.
umount /run/cilium/cgroupv2 2>/dev/null || true

# cilium_net is cilium_host's veth peer and goes with it. Per-endpoint lxc* veths go
# with their containers.
ip link del cilium_host 2>/dev/null || true
ip link del cilium_vxlan 2>/dev/null || true

# /var/lib/cilium does not exist on this node today (endpoint state lives under
# /var/run/cilium/state); it is listed because Cilium uses it when state-dir is moved
# off tmpfs, and the rm is a no-op when absent.
rm -rf /var/run/cilium /var/lib/cilium

# bpffs is its own mount, so nothing above touches the pinned maps -- cilium_ipcache,
# cilium_lxc, cilium_lb4_services_v2, cilium_tunnel_map. Cilium itself only clears them
# via the clean-cilium-state init container, which needs CLEAN_CILIUM_STATE, and the
# bootstrap install does not set it. Without this the agent comes up on the new pool
# reading maps still full of 10.0.0.0/24.
#
# find, not a `cilium_*` glob: this script has no shebang, so it runs under whatever
# shell invokes it, and in zsh a glob that matches nothing is a fatal error for the
# command rather than a literal passed through as it is in bash -- the cleanup would be
# skipped on exactly the runs where the directory is already clean.
find /sys/fs/bpf/tc/globals -maxdepth 1 -name 'cilium_*' -exec rm -rf {} + 2>/dev/null || true
rm -rf /sys/fs/bpf/cilium

# Run as root via sudo, so ~ is /root -- that misses the invoking user's config,
# the one the playbook installs. Both are stale after a nuke: root's if the
# operator did the kubeadm post-init copy so `sudo kubectl` works, the user's
# from playbook.yml. Drop both, otherwise a rebuild yields x509 errors against
# the new CA that look unrelated to the reset.
NUKE_USER=${SUDO_USER:-$USER}
NUKE_HOME=$(getent passwd "$NUKE_USER" | cut -d: -f6)
rm -rf /root/.kube
rm -rf "${NUKE_HOME:?unable to resolve home for $NUKE_USER}/.kube"

systemctl restart containerd

crictl ps