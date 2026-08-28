# you might need to install crictl
# VERSION="v1.31.1"
# wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
# sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
# rm -f crictl-$VERSION-linux-amd64.tar.gz

kubeadm reset -f

rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes
# Run as root via sudo, so ~ is /root -- that misses the invoking user's config,
# the one the playbook installs. Both are stale after a nuke: root's if the
# operator did the kubeadm post-init copy so `sudo kubectl` works, the user's
# from playbook.yml. Drop both, otherwise a rebuild yields x509 errors against
# the new CA that look unrelated to the reset.
NUKE_USER=${SUDO_USER:-$USER}
NUKE_HOME=$(getent passwd "$NUKE_USER" | cut -d: -f6)
rm -rf /root/.kube "${NUKE_HOME:?unable to resolve home for $NUKE_USER}/.kube"

systemctl restart containerd

crictl ps