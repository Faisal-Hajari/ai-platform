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
  # Per-chart. `fail` used to be the only flag and was never reset, so once any chart
  # failed, every chart after it stopped printing `ok` and read as though it had failed
  # too. (It did not abort the run: the trailing `[ "$fail" -eq 0 ] && echo` sits before
  # the final `&&` of an AND-list, which is one of the cases `set -e` exempts.)
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
if pool_errors=$(python3 - 2>&1 <<'PY'
import ipaddress, pathlib, sys, yaml

values = pathlib.Path("deployment/kube-system/cilium/values.yaml")
pool_dir = pathlib.Path("deployment/kube-system/cilium-config")

errors = []
blocks = []   # (label, first, last) for every block that could serve the ingress
skipped = []  # pools deliberately not counted, and why

def parse_block(name, block):
    """(label, first address, last address), or ValueError if the block is malformed."""
    if "cidr" in block:
        # strict=False because that is what LB-IPAM does: it normalizes a host address
        # to its network, so a block written "192.168.100.200/28" really offers
        # .192-.207 (#8). Checking the literal string instead would call a pin inside
        # the pool when it is only inside the range someone meant to write.
        net = ipaddress.ip_network(block["cidr"], strict=False)
        return f"{name}: {block['cidr']}", net[0], net[-1]
    first, last = ipaddress.ip_address(block["start"]), ipaddress.ip_address(block["stop"])
    if last < first:
        raise ValueError(f"stop {last} precedes start {first}")
    return f"{name}: {first}-{last}", first, last

# *.y*ml, not *.yaml: ArgoCD's directory sync applies both spellings, and reading only
# half the pools would let a pin look homeless when it is not, or vice versa.
for path in sorted(pool_dir.glob("*.y*ml")):
    try:
        docs = list(yaml.safe_load_all(path.read_text()))
    except (OSError, yaml.YAMLError) as exc:
        errors.append(f"{path} could not be read: {exc}")
        continue
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "CiliumLoadBalancerIPPool":
            continue
        name = (doc.get("metadata") or {}).get("name") or path.name
        spec = doc.get("spec") or {}
        # A pool that cannot hand this service an address is not containment, however
        # well its blocks cover the pin. spec.disabled takes the whole pool out of
        # service; spec.serviceSelector narrows it to services it matches, and the
        # ingress service's labels are the upstream chart's to set, not this repo's --
        # so rather than guess at a match, refuse to count the pool and name it in the
        # failure. Both directions stay closed: an unservable pool cannot satisfy the
        # check, and an operator who meant it to serve the ingress is told why it did
        # not count.
        if spec.get("disabled"):
            skipped.append(f"{name} (disabled)")
            continue
        if spec.get("serviceSelector"):
            skipped.append(f"{name} (serviceSelector, not evaluated)")
            continue
        for index, block in enumerate(spec.get("blocks") or []):
            try:
                blocks.append(parse_block(name, block))
            except (KeyError, TypeError, ValueError) as exc:
                errors.append(f"{name} block {index} is malformed ({exc}): {block!r}")

try:
    service = (((yaml.safe_load(values.read_text()) or {}).get("cilium") or {})
               .get("ingressController") or {}).get("service") or {}
    pin = (service.get("annotations") or {}).get("lbipam.cilium.io/ips")
except (OSError, yaml.YAMLError, AttributeError) as exc:
    errors.append(f"{values} could not be read: {exc}")
    pin = None

if not blocks:
    detail = f" (skipped {', '.join(skipped)})" if skipped else ""
    errors.append(f"no usable CiliumLoadBalancerIPPool block found under {pool_dir}{detail}")
if not pin:
    # Not merely cosmetic, and not a vacuous pass to skip over: unpinned, the shared
    # entrypoint takes whatever LB-IPAM hands out and the ingress A records rot. A
    # misspelled annotation key looks exactly like this, and Kubernetes accepts it.
    errors.append(f"no lbipam.cilium.io/ips on the ingress service in {values}")

for text in (pin or "").split(","):
    text = text.strip()
    if not text:
        continue
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        errors.append(f"lbipam.cilium.io/ips value {text!r} is not an IP address"
                      " -- the annotation takes bare addresses, not CIDRs")
        continue
    # `blocks` empty is already its own failure above -- saying the pin is outside a
    # pool that does not exist on top of it just buries the reason.
    if blocks and not any(first.version == ip.version and first <= ip <= last for _, first, last in blocks):
        detail = f"; skipped {', '.join(skipped)}" if skipped else ""
        spelled = ", ".join(label for label, _, _ in blocks) or "none"
        errors.append(f"ingress pin {ip} is outside every pool block that can serve it"
                      f" ({spelled}){detail}")

print("\n".join(errors))
sys.exit(1 if errors else 0)
PY
); then
  echo "    ok"
else
  # 2>&1 above, so an exception this block does not anticipate arrives here as its
  # traceback rather than as a blank FAIL with the reason on an uncaptured stderr.
  while IFS= read -r line; do
    echo "    FAIL: $line"
  done <<<"$pool_errors"
  fail=1
fi

exit "$fail"
