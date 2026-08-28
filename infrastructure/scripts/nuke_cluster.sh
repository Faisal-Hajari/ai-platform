# you might need to install crictl
# VERSION="v1.31.1"
# wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
# sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
# rm -f crictl-$VERSION-linux-amd64.tar.gz

kubeadm reset -f

rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes

# kubeadm reset explicitly leaves CNI-created interfaces and any state outside
# /etc/kubernetes alone, so Cilium's node-local state outlives the nuke: cilium_host
# keeps the old router IP (and its /24 route), cilium_vxlan the old tunnel, and
# /var/run/cilium + /var/lib/cilium the endpoint and IPAM state keyed to the old pool.
#
# That was harmless while the pod CIDR never changed. It is not once it does: on the
# first rebuild onto a new pool the restored router IP sits outside the new allocation
# CIDR. The agent is supposed to notice and discard it; clearing the state outright
# means not depending on that on the one run where rollback is hardest.
#
# cilium_net is cilium_host's veth peer and goes with it. Per-endpoint lxc* veths go
# with their containers.
ip link del cilium_host 2>/dev/null || true
ip link del cilium_vxlan 2>/dev/null || true
rm -rf /var/run/cilium /var/lib/cilium

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