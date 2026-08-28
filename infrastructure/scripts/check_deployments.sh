# Renders every chart under deployment/ the way ArgoCD will and asserts the
# invariants that have bitten this cluster before. Run before pushing changes
# to deployment/ -- a bad value here is accepted silently and only shows up
# later as a CrashLoop.
#
# Note that `helm dependency update` writes into the chart's charts/ directory and
# never prunes it. charts/ and Chart.lock are gitignored, so a stale copy left over
# from a chart that has since been deleted -- deployment/ingress/nginx/charts/, gone
# from git since #20 -- is invisible to git and would still be rendered here if its
# parent directory were ever recreated. Delete such a directory outright rather than
# just emptying Chart.yaml's dependencies.

set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0

for chart in deployment/*/*/Chart.yaml; do
  dir=$(dirname "$chart")
  # Per-chart, so one bad chart does not mask the checks on the ones after it. The
  # loop body must also not END on a failed test: under `set -e` that would exit the
  # shell mid-loop and leave the remaining charts unrendered.
  chart_fail=0
  echo "==> $dir"
  helm dependency update "$dir" >/dev/null
  render=$(helm template "$(basename "$dir")" "$dir")

  # These are umbrella charts: values only reach the upstream chart when they are
  # nested under the dependency's name. A top-level key that matches no dependency
  # is not an error to Helm, it is just ignored -- and the defaults apply instead.
  orphans=$(python3 - "$dir" <<'PY'
import sys, yaml, pathlib
d = pathlib.Path(sys.argv[1])
deps = {x["name"] for x in (yaml.safe_load((d/"Chart.yaml").read_text()).get("dependencies") or [])}
vals = yaml.safe_load((d/"values.yaml").read_text()) or {}
print(" ".join(k for k in vals if k not in deps))
PY
)
  if [ -n "$orphans" ]; then
    echo "    FAIL: values.yaml keys match no dependency and will be ignored: $orphans"
    chart_fail=1
  fi

  # Cilium replaces kube-proxy, so it cannot reach the API server through the
  # ClusterIP that only it can program. Without k8sServiceHost the chart omits
  # KUBERNETES_SERVICE_HOST and Cilium deadlocks against 10.96.0.1 on restart,
  # taking every other pod down with it.
  if [ "$(basename "$dir")" = "cilium" ]; then
    if ! grep -q KUBERNETES_SERVICE_HOST <<<"$render"; then
      echo "    FAIL: no KUBERNETES_SERVICE_HOST in the render -- set cilium.k8sServiceHost"
      chart_fail=1
    fi
  fi

  if [ "$chart_fail" -eq 0 ]; then
    echo "    ok"
  else
    fail=1
  fi
done

# cilium-config/ is plain manifests with no Chart.yaml, so the loop above never looks
# at it -- and the invariant that matters most spans it and the chart. The shared
# ingress entrypoint is pinned in cilium/values.yaml; the pool that address has to come
# out of is declared here. They are two ArgoCD Applications with no ordering between
# their syncs, so they can disagree transiently even when each file is right on its own.
#
# When the pin lands outside the pool, LB-IPAM sets IPAMRequestSatisfied=False on
# kube-system/cilium-ingress, the service never gets an address, and every Ingress in
# the cluster is dead. It does not self-heal: LB-IPAM will not evict a holder to make
# room, so the condition just persists. Both halves are static YAML, so assert
# containment here instead of learning it from the cluster (#26).
echo "==> deployment/kube-system/cilium-config"
if pool_errors=$(python3 - <<'PY'
import ipaddress, pathlib, sys, yaml

values = pathlib.Path("deployment/kube-system/cilium/values.yaml")
pool_dir = pathlib.Path("deployment/kube-system/cilium-config")

def contains(block, ip):
    if "cidr" in block:
        # strict=False because that is what LB-IPAM does: it normalizes a host address
        # to its network, so a block written "192.168.100.200/28" really offers
        # .192-.207 (#8). Checking the literal string instead would call a pin inside
        # the pool when it is only inside the range someone meant to write.
        return ip in ipaddress.ip_network(block["cidr"], strict=False)
    return ipaddress.ip_address(block["start"]) <= ip <= ipaddress.ip_address(block["stop"])

blocks = []
for path in sorted(pool_dir.glob("*.yaml")):
    for doc in yaml.safe_load_all(path.read_text()):
        if isinstance(doc, dict) and doc.get("kind") == "CiliumLoadBalancerIPPool":
            name = (doc.get("metadata") or {}).get("name", path.name)
            blocks += [(name, b) for b in ((doc.get("spec") or {}).get("blocks") or [])]

service = (((yaml.safe_load(values.read_text()) or {}).get("cilium") or {})
           .get("ingressController") or {}).get("service") or {}
pin = (service.get("annotations") or {}).get("lbipam.cilium.io/ips")

errors = []
if not blocks:
    errors.append(f"no CiliumLoadBalancerIPPool blocks found under {pool_dir}")
if not pin:
    # Not merely cosmetic, and not a vacuous pass to skip over: unpinned, the shared
    # entrypoint takes whatever LB-IPAM hands out and the ingress A records rot. A
    # misspelled annotation key looks exactly like this, and Kubernetes accepts it.
    errors.append(f"no lbipam.cilium.io/ips on the ingress service in {values}")

for text in (pin or "").split(","):
    text = text.strip()
    if not text:
        continue
    ip = ipaddress.ip_address(text)
    if not any(contains(b, ip) for _, b in blocks):
        spelled = ", ".join(
            f"{n}: {b['cidr']}" if "cidr" in b else f"{n}: {b['start']}-{b['stop']}"
            for n, b in blocks
        )
        errors.append(f"ingress pin {ip} is outside every pool block ({spelled})")

print("\n".join(errors))
sys.exit(1 if errors else 0)
PY
); then
  echo "    ok"
else
  while IFS= read -r line; do
    echo "    FAIL: $line"
  done <<<"$pool_errors"
  fail=1
fi

exit "$fail"
