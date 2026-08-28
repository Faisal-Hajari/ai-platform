#!/usr/bin/env bash
# Recovers a cluster where Cilium is stuck dialing https://10.96.0.1:443 and CrashLooping.
#
# Because kubeadm runs with --skip-phases=addon/kube-proxy, nothing programs the
# kubernetes ClusterIP until Cilium is up -- so Cilium cannot reach the API server
# through it. The chart only injects KUBERNETES_SERVICE_HOST/PORT when k8sServiceHost is
# set in infrastructure/k8s-ansible/system-apps/cilium/values.yaml, and that address is
# a DHCP lease: when the lease moves, the pinned value is stale and Cilium deadlocks
# against 10.96.0.1 on its next restart.
#
# The patches below are a stopgap either way, but what undoes them has changed. ArgoCD
# no longer syncs this chart, so nothing reverts them within minutes any more -- the
# next `helm upgrade --install` from the playbook does, which is also the thing that
# reads the corrected values.yaml. So: patch to get the cluster back, fix k8sServiceHost
# (the playbook asserts it is an address this host holds), then re-run the playbook.
# Note that a moved lease also leaves the API server advertising the old address, which
# these patches cannot fix -- see the DHCP paragraph in README.md.

set -euo pipefail

API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
API_HOST=${API#https://}; API_PORT=${API_HOST##*:}; API_HOST=${API_HOST%:*}
echo "Pointing Cilium at API server ${API_HOST}:${API_PORT}"

kubectl -n kube-system patch ds cilium -p "$(cat <<YAML
spec:
  template:
    spec:
      initContainers:
      - name: config
        env:
        - {name: KUBERNETES_SERVICE_HOST, value: "$API_HOST"}
        - {name: KUBERNETES_SERVICE_PORT, value: "$API_PORT"}
      containers:
      - name: cilium-agent
        env:
        - {name: KUBERNETES_SERVICE_HOST, value: "$API_HOST"}
        - {name: KUBERNETES_SERVICE_PORT, value: "$API_PORT"}
YAML
)"

kubectl -n kube-system patch deploy cilium-operator -p "$(cat <<YAML
spec:
  template:
    spec:
      containers:
      - name: cilium-operator
        env:
        - {name: KUBERNETES_SERVICE_HOST, value: "$API_HOST"}
        - {name: KUBERNETES_SERVICE_PORT, value: "$API_PORT"}
YAML
)"

kubectl -n kube-system rollout status ds/cilium --timeout=180s
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=180s

# Pods that never got a sandbox need a bounce once the CNI is back.
kubectl -n kube-system delete pod -l k8s-app=kube-dns --ignore-not-found

kubectl get pods -A
