# you might need to install crictl
# VERSION="v1.31.1"
# wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
# sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
# rm -f crictl-$VERSION-linux-amd64.tar.gz

kubeadm reset -f

rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes
rm -rf ~/.kube

systemctl restart containerd

crictl ps