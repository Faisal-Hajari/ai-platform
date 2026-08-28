#!/usr/bin/env bash
# Renders every chart under deployment/ the way ArgoCD will and asserts the
# invariants that have bitten this cluster before. Run before pushing changes
# to deployment/ -- a bad value here is accepted silently and only shows up
# later as a CrashLoop.

set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0

for chart in deployment/*/*/Chart.yaml; do
  dir=$(dirname "$chart")
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
    fail=1
  fi

  # Cilium replaces kube-proxy, so it cannot reach the API server through the
  # ClusterIP that only it can program. Without k8sServiceHost the chart omits
  # KUBERNETES_SERVICE_HOST and Cilium deadlocks against 10.96.0.1 on restart,
  # taking every other pod down with it.
  if [ "$(basename "$dir")" = "cilium" ]; then
    if ! grep -q KUBERNETES_SERVICE_HOST <<<"$render"; then
      echo "    FAIL: no KUBERNETES_SERVICE_HOST in the render -- set cilium.k8sServiceHost"
      fail=1
    fi
  fi

  [ "$fail" -eq 0 ] && echo "    ok"
done

exit "$fail"
