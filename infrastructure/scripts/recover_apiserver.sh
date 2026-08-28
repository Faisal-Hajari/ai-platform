# Recovers a static pod stuck in CreateContainerError with "failed to reserve container
# name ... is reserved for <id>", while the container it represents is still running and
# serving normally.
#
# Cause is a backward clock step after boot (chrony's `makestep 1 3` firing once kubelet
# and containerd are already timestamping container lifecycle events). kubelet concludes
# the live container died, tries to create the next attempt, and containerd refuses
# because the name belongs to a half-created container that was never cleaned up.
#
# Neither daemon gives up on its own, and restarting them does not help: the reservation
# is persisted in /var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db, and running
# containers survive a containerd restart via their containerd-shim. Both container
# objects have to go -- removing only the orphan frees the name but leaves the old
# container holding the host port, trading this error for a bind failure.
#
# The permanent fix is in infrastructure/k8s-ansible/playbook.yml (hold kubelet and
# containerd behind time-sync.target); this only unsticks a node that is already wedged.
#
# Usage: sudo ./recover_apiserver.sh [pod-name-prefix]   (default: kube-apiserver)

set -euo pipefail

POD=${1:-kube-apiserver}

command -v crictl >/dev/null || { echo "crictl not found -- see nuke_cluster.sh header"; exit 1; }

# Every container object for the pod, running or not: the live one and the orphan that
# holds the name reservation.
IDS=$(crictl ps -a --name "^${POD}$" -q)

if [ -z "$IDS" ]; then
  echo "No containers found for ${POD}; nothing to do."
  exit 0
fi

echo "Removing every container object for ${POD}:"
crictl ps -a --name "^${POD}$"

# The half-created container has no running task, so -f is what makes this uniform.
# shellcheck disable=SC2086 -- IDs are hex, word splitting is the point here.
crictl rm -f $IDS

# kubelet rebuilds the static pod on its next sync (~every 15s off the manifest watch).
echo "Waiting for kubelet to rebuild ${POD}..."
for _ in $(seq 30); do
  if crictl ps --name "^${POD}$" -q | grep -q .; then
    echo "Recreated:"
    crictl ps --name "^${POD}$"
    exit 0
  fi
  sleep 5
done

echo "${POD} did not come back within 150s -- check 'journalctl -u kubelet -n 100'." >&2
exit 1
