# you might need to install crictl
# VERSION="v1.31.1"
# wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
# sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
# rm -f crictl-$VERSION-linux-amd64.tar.gz

kubeadm reset -f

rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes
# Run as root via sudo, so ~ is /root -- resolve the invoking user's real home
# instead, otherwise their kubeconfig survives the nuke with credentials for a
# cluster that no longer exists.
NUKE_USER=${SUDO_USER:-$USER}
NUKE_HOME=$(getent passwd "$NUKE_USER" | cut -d: -f6)
rm -rf "${NUKE_HOME:?unable to resolve home for $NUKE_USER}/.kube"

systemctl restart containerd

crictl ps