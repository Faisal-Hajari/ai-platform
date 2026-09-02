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

# Guarded, and then matched against the shape it has to be (#58). The bare assignment
# adopted kubectl's status under `set -e`, so a kubeconfig this user cannot read ended the
# script with nothing of its own to say: kubectl's error reached the terminal, but not a
# word about which step had failed or whether anything had been patched.
#
# The match matters more than the status. A kubectl that *succeeds* naming no cluster
# prints nothing and exits 0, and the `${API#https://}` parse this replaces turned that
# into empty KUBERNETES_SERVICE_HOST/PORT values patched straight into the DaemonSet and
# the operator -- a recovery script deepening the outage, and printing "Pointing Cilium at
# API server :" while it did. Three more shapes landed in the same place, because that
# parse assumed the scheme and `${API_HOST##*:}` on a string with no colon returns the
# whole string:
#
#   https://host           PORT set to the hostname
#   http://host:6443       HOST set to "http://host"
#   https://host:6443/     PORT set to "6443/"
#
# One anchored match covers all four and refuses anything else rather than mangling it,
# which is the right direction for a value whose only use is being written into two
# workloads. A bracketed IPv6 literal is accepted and unwrapped -- the vendored chart passes
# k8sServiceHost through verbatim, and client-go's InClusterConfig re-brackets it through
# net.JoinHostPort, so the env var takes an address and a bracketed one would double up.
# `_` is in the host class only to keep the breadth the old parse had: it is invalid in a DNS
# hostname and kubeadm writes an address, but newly refusing it would be a regression rather
# than the fix this is.
API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') || {
  echo "cannot read the API server address from the kubeconfig (kubectl's error is above)." >&2
  exit 1
}
if [[ ! "$API" =~ ^https://([0-9A-Za-z._-]+|\[[0-9A-Fa-f:]+\]):([0-9]+)$ ]]; then
  echo "the current context names no usable API server address (got '${API:-<empty>}')." >&2
  echo "Expected https://<host>:<port>. Check \`kubectl config current-context\` --" >&2
  echo "Cilium cannot be pointed at nothing, and will not be pointed at a guess." >&2
  exit 1
fi
API_HOST=${BASH_REMATCH[1]}; API_HOST=${API_HOST#"["}; API_HOST=${API_HOST%"]"}
API_PORT=${BASH_REMATCH[2]}
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
