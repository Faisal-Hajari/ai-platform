# Recovers a static pod stuck in CreateContainerError with "failed to reserve container
# name ... is reserved for <id>", while the container it represents is still running and
# serving normally.
#
# Cause is a backward clock step after boot (chrony's `makestep 1 3` firing once kubelet
# and containerd are already timestamping container lifecycle events). kubelet concludes
# the live container died, tries to create the next attempt, and containerd refuses
# because the name belongs to a half-created container that was never cleaned up.
#
# Restarting containerd does not help when the orphan container record survives in bolt:
# the CRI name registrar is in-memory, but on startup containerd re-reserves names for
# every container it recovers from the store, so the same reservation comes straight
# back. (A reservation with no surviving record would clear on restart -- and a restart
# is the cheaper thing to try first, since running containers survive it via their
# containerd-shim.) Once the record is there, both container objects have to go:
# removing only the orphan frees the name but leaves the old container holding the host
# port, trading this error for a bind failure.
#
# The permanent fix is in infrastructure/k8s-ansible/playbook.yml (hold kubelet and
# containerd behind time-sync.target); this only unsticks a node that is already wedged.
#
# Usage: sudo bash recover_apiserver.sh [container-name]   (default: kube-apiserver)
#
# The argument is a CRI container name, not a pod name: kube-apiserver, etcd,
# kube-scheduler, kube-controller-manager.

set -euo pipefail

NAME=${1:-kube-apiserver}

command -v crictl >/dev/null || { echo "crictl not found -- see nuke_cluster.sh header"; exit 1; }

# Every container object by this name, running or not: the live one and the orphan that
# holds the reservation.
IDS=$(crictl ps -a --name "^${NAME}$" -q)

if [ -z "$IDS" ]; then
  echo "No containers found named ${NAME}; nothing to do."
  exit 0
fi

# A single object means there is no orphan -- either the node is healthy or the
# reservation already cleared. Deleting it would take the API server down for nothing.
if [ "$(printf '%s\n' "$IDS" | wc -l)" -lt 2 ]; then
  echo "Only one container object for ${NAME}; no orphan to clear."
  echo "Not removing a healthy container."
  exit 0
fi

echo "Removing every container object for ${NAME}:"
crictl ps -a --name "^${NAME}$"

# The half-created container has no running task, so -f is what makes this uniform.
# shellcheck disable=SC2086 -- IDs are hex, word splitting is the point here.
crictl rm -f $IDS

# kubelet rebuilds the static pod on its next sync (~every 15s off the manifest watch).
echo "Waiting for kubelet to rebuild ${NAME}..."
for _ in $(seq 30); do
  if crictl ps --name "^${NAME}$" -q | grep -q .; then
    echo "Recreated:"
    crictl ps --name "^${NAME}$"
    exit 0
  fi
  sleep 5
done

echo "${NAME} did not come back within 150s -- check 'journalctl -u kubelet -n 100'." >&2
exit 1
