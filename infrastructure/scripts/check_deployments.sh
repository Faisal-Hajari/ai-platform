#!/usr/bin/env bash
# Renders every chart in this repo the way its deployer will and asserts the invariants
# that have bitten this cluster before. Run before pushing changes to either half -- a
# bad value here is accepted silently and only shows up later as a CrashLoop.
#
# Two halves, rendered the way each deployer renders it -- `helm template` for both, but
# with that deployer's release name and namespace, which some charts read:
# infrastructure/k8s-ansible/system-apps/*/ is applied by the Ansible play (see
# system-apps/README.md), and deployment/*/*/ is synced by ArgoCD. deployment/ is empty
# today and that is not a failure -- the charts array below simply matches nothing there.
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

# The cross-file check after the loop asserts against the render, not against
# values.yaml, so it needs the cilium chart's output to outlive the iteration that
# produced it -- `render` is overwritten by every chart after it.
ingress_render=$(mktemp)
gpu_render=$(mktemp)
trap 'rm -f "$ingress_render" "$gpu_render"' EXIT

cilium_dir=infrastructure/k8s-ansible/system-apps/cilium
gpu_dir=infrastructure/k8s-ansible/system-apps/gpu-operator

# Without nullglob an empty deployment/ hands the unexpanded pattern to helm, and the
# run ends on helm's complaint about a directory named `*` -- an error that says nothing
# about the invariants that went unchecked. Both patterns are globs for that reason,
# including the system-apps one, which matches $cilium_dir and the argocd chart: a chart
# that has gone missing should reach the cross-file check below, which says what it was
# needed for, rather than take the run down on a helm error first.
#
# ArgoCD only reaches this loop at all because it is a chart now. While it installed from
# a pinned upstream URL its directory held no Chart.yaml, so nothing here rendered it and
# a broken value in it would have been found by a bootstrap rather than by CI.
#
# There is no "no charts found" failure any more either. deployment/ matching nothing is
# the normal state now that the CNI has moved out of it, and it stops being a failure
# the moment it would fire on every run.
shopt -s nullglob
charts=(infrastructure/k8s-ansible/system-apps/*/Chart.yaml deployment/*/*/Chart.yaml)

for chart in "${charts[@]}"; do
  dir=$(dirname "$chart")
  # Per-chart. `fail` used to be the only flag and was never reset, so once any chart
  # failed, every chart after it stopped printing `ok` and read as though it had failed
  # too. (It did not abort the run: the trailing `[ "$fail" -eq 0 ] && echo` sits before
  # the final `&&` of an AND-list, which is one of the cases `set -e` exempts.)
  chart_fail=0
  echo "==> $dir"
  helm dependency update "$dir" >/dev/null

  # Release name and namespace taken from the deployer rather than left to helm's defaults,
  # because a chart can read either and these do. Not cosmetic: NVIDIA's charts call `fail`
  # outright on `.Release.Namespace == "default"`, so a bare `helm template` would report a
  # perfectly correct chart as broken -- and the reverse is the worse hazard, since a chart
  # keying anything off the namespace would be checked in one nothing deploys it to.
  #
  # ArgoCD names the release after the Application, which the ApplicationSet template builds
  # as `<path[1]>-<basename>`, and syncs it into namespace `<path[1]>`.
  #
  # For system-apps/ the namespace is read back out of the play rather than restated here,
  # the same treatment the CI workflow gives helm_version. The variable name is derived from
  # the directory -- system-apps/gpu-operator needs `gpu_operator_namespace` -- so adding a
  # chart there means adding one var, not editing this script. A chart with no such var
  # fails: the play could not deploy it either, and this is the cheap place to find out.
  case "$dir" in
    deployment/*)
      namespace=$(basename "$(dirname "$dir")")
      release="$namespace-$(basename "$dir")"
      ;;
    *)
      release=$(basename "$dir")
      # 2>&1, like every other python block here: sys.exit(msg) writes to stderr, so
      # without it a missing var arrives as a blank FAIL with the reason discarded.
      if ! namespace=$(SYSTEM_APP="$release" python3 - 2>&1 <<'NSPY'
import os, pathlib, sys, yaml
play = yaml.safe_load(pathlib.Path("infrastructure/k8s-ansible/playbook.yml").read_text())[0]
var = os.environ["SYSTEM_APP"].replace("-", "_") + "_namespace"
value = (play.get("vars") or {}).get(var)
if not value:
    sys.exit(f"playbook.yml declares no {var}")
print(value)
NSPY
      ); then
        echo "    FAIL: $namespace"
        fail=1
        continue
      fi
      ;;
  esac
  render=$(helm template "$release" "$dir" --namespace "$namespace")

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
  # Matched on the whole path, not the basename: a future deployment/<ns>/cilium is a
  # different chart, and letting it overwrite this render would check the pool against
  # the wrong one.
  if [ "$dir" = "$cilium_dir" ]; then
    if ! grep -q KUBERNETES_SERVICE_HOST <<<"$render"; then
      echo "    FAIL: no KUBERNETES_SERVICE_HOST in the render -- set cilium.k8sServiceHost"
      chart_fail=1
    fi
    printf '%s\n' "$render" >"$ingress_render"
  fi

  if [ "$dir" = "$gpu_dir" ]; then
    printf '%s\n' "$render" >"$gpu_render"
  fi

  if [ "$chart_fail" -eq 0 ]; then
    echo "    ok"
  else
    fail=1
  fi
done

# config/ is plain manifests with no Chart.yaml, so the loop above never looks at it --
# and the invariant that matters most spans it and the chart. The shared ingress
# entrypoint is pinned in cilium/values.yaml; the pool that address has to come out of
# is declared here. The playbook applies the two in one step now, so they can no longer
# disagree merely because two Applications synced in an arbitrary order -- but nothing
# stops one file being edited without the other, which is what this asserts.
#
# Three claims -- two about that one address, one about the pools themselves:
#
#   containment -- a pool that can serve kube-system/cilium-ingress covers the pin. When
#   none does, LB-IPAM sets IPAMRequestSatisfied=False on the Service, it never gets an
#   address, and every Ingress in the cluster is dead (#26).
#
#   exclusivity -- no pool that serves anything else covers it. LB-IPAM hands an unpinned
#   Service the lowest address of the smallest free block of the first pool that matches
#   it, so an address inside a general pool is an address that can be given away -- and
#   once it is, the pin cannot take it back, because LB-IPAM will not evict a holder to
#   make room. Same dead ingress, reached from a Service that never named the address
#   (#69).
#
#   no overlap -- no two pool blocks intersect. Cilium settles an overlap by marking one
#   of the two pools Conflicting and internally disabling *every* range it has, so an
#   overlap does not trim a pool, it switches one off; which one is decided by
#   CreationTimestamp, which is not in git. When the one switched off is the pool holding
#   the pin, that is #69's failure again, reached through the reservation itself.
#
# None of the three self-heals, and all of it is static YAML, so assert it here instead of
# learning it from the cluster.
#
# How *widely* a reserving selector is drawn is asked twice, because neither question
# covers the other. Of the render: a selector that also matches another Service the chart
# renders is proven broad and fails -- one-sided by construction, since the cluster holds
# Services this never sees, but broad is the direction that turns a reservation into a
# fiction, and app.kubernetes.io/part-of=cilium is on all three Services this chart renders
# and reads exactly like a reservation until something asks. And of its shape: a selector
# needs one positive term, because NotIn and DoesNotExist only remove Services from a set
# nothing bounded. That one cannot come from the render -- `DoesNotExist: k8s-app` matches
# only cilium-ingress here, since the other two Services carry that label, so the render
# calls it narrow while the cluster hands it nearly everything.
#
# Two things stay open, and are limits of this script rather than of the idea. Namespace:
# config/ip-pool.yaml selects on io.kubernetes.service.name, which names one Service per
# namespace, and name *and* namespace would be narrower still -- not used only because this
# script renders with no --namespace while the play installs into kube-system, so the render
# cannot answer the namespace half. That is a property of how the render is made here rather
# than of `helm template`: passing the play's namespace to the cilium render would close it,
# at the cost of making the namespace a per-chart value in the loop above. And a pool that
# exists in the cluster but not in git: `kubectl apply -f` has no prune, so one deleted or
# renamed here can outlive its manifest and go on handing out the pin.
#
# The pool also has to be announced, and that is a second invariant with a worse failure
# than the first: without a CiliumL2AnnouncementPolicy covering LoadBalancer addresses,
# LB-IPAM still allocates, the Service still shows an EXTERNAL-IP and
# IPAMRequestSatisfied stays true -- nothing in the cluster reports anything wrong, and
# the address is simply unreachable from the LAN (#39). Delete l2-policy.yaml and every
# check above still passes, so its existence is asserted below.
#
# Only the half of that the files can answer is asked here. Which interface a policy
# matches, and whether the pool sits on that interface's subnet, are properties of the
# machine: the subnet is a DHCP lease and appears nowhere in git. That half is asserted
# by infrastructure/k8s-ansible/playbook.yml, against the host, before it touches it.
echo "==> $cilium_dir/config"
if pool_errors=$(CILIUM_DIR="$cilium_dir" INGRESS_RENDER="$ingress_render" python3 - 2>&1 <<'PY'
import ipaddress, os, pathlib, sys, yaml

chart = pathlib.Path(os.environ["CILIUM_DIR"])
values = chart / "values.yaml"
config_dir = chart / "config"
render = pathlib.Path(os.environ["INGRESS_RENDER"])

INGRESS_SERVICE = "cilium-ingress"
# The two labels LB-IPAM synthesizes onto a Service before matching a pool's
# serviceSelector against it (operator/pkg/lbipam/service_store.go). Everything else it
# matches on is the Service's own labels, which the render carries.
NAME_LABEL = "io.kubernetes.service.name"
NAMESPACE_LABEL = "io.kubernetes.service.namespace"

errors = []
blocks = []   # (label, first, last, serves_ingress, reserved, open_reason) per live block
skipped = []  # pools deliberately not counted, and why

def parse_block(name, block, allow_first_last):
    """(label, servable first, servable last, range first, range last).

    The last two are the range LB-IPAM's LBRange actually covers, which the overlap check
    below needs and which allowFirstLastIPs does not change: Cilium withholds the first and
    last addresses of a CIDR by pre-allocating them, not by narrowing the range, so two
    pools that meet only there still conflict. ValueError if the block is malformed.
    """
    if "cidr" in block:
        # strict=False because that is what LB-IPAM does: it normalizes a host address
        # to its network, so a block written "192.168.100.200/28" really offers
        # .192-.207 (#8). Checking the literal string instead would call a pin inside
        # the pool when it is only inside the range someone meant to write.
        net = ipaddress.ip_network(block["cidr"], strict=False)
        first, last = net[0], net[-1]
        # allowFirstLastIPs: "No" withholds the network and broadcast addresses, so a
        # pin on either renders fine and is then never servable -- the same shape as a
        # disabled pool. A /31 or /32 has nothing left after that narrowing and LB-IPAM
        # hands both addresses out regardless, so leave those alone.
        host_bits = net.max_prefixlen - net.prefixlen
        if not allow_first_last and host_bits > 1:
            first, last = net[1], net[-2]
        # Both spellings, because neither transformation above is visible in the literal
        # and the message is the whole operator-facing surface of this check. Told only
        # that .192 is outside "192.168.100.200/28" -- which contains it -- the reader
        # would reasonably conclude the checker is broken.
        return f"{name}: {block['cidr']} ({first}-{last})", first, last, net[0], net[-1]
    # `stop` is optional to LB-IPAM: a block with a start and no stop is the single
    # address `start` (ipRangeFromBlock), which is the natural way to write a one-address
    # reservation. Requiring it here reported such a block as malformed.
    first = ipaddress.ip_address(block["start"])
    last = ipaddress.ip_address(block["stop"]) if block.get("stop") else first
    if last < first:
        raise ValueError(f"stop {last} precedes start {first}")
    if first == last:
        return f"{name}: {first}", first, last, first, last
    return f"{name}: {first}-{last}", first, last, first, last

def label_value(value):
    """A YAML scalar as Kubernetes would have stored the label value."""
    # Label values are strings, but nothing stops a selector being written with a bare
    # `true`, which YAML hands over as a bool -- and str(True) is "True", which matches
    # no label a chart ever writes.
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)

def selector_bounds(selector):
    """None if the selector bounds what it matches, else the clause saying why it does not.

    A reservation is a claim that one Service and no other can be given an address, so the
    selector has to bound the set it matches: at least one positive term -- a matchLabels
    entry, an In, or an Exists. NotIn and DoesNotExist only ever remove Services from a set
    nothing bounded, so a selector built of those alone matches nearly everything.

    Asked by shape rather than of the render, because the render is exactly what cannot see
    it. `DoesNotExist: k8s-app` matches only cilium-ingress among the three Services this
    chart renders -- the other two carry that label -- so the breadth check below reports it
    as matching one Service and would wave it through, while in the cluster it matches
    nearly every Service there is. Its narrowness is an accident of what happens to be in
    the render.
    """
    match_labels = selector.get("matchLabels") or {}
    expressions = [e for e in (selector.get("matchExpressions") or []) if isinstance(e, dict)]
    if not match_labels and not expressions:
        # Cilium's match-all: LabelSelectorAsSelector of an empty selector is
        # labels.Everything(), so this is not a narrowing at all.
        return ("has an empty serviceSelector, which Cilium reads as match-all, so it serves"
                " every LoadBalancer Service")
    if not (match_labels or any(e.get("operator") in ("In", "Exists") for e in expressions)):
        return ("has a serviceSelector of only NotIn and DoesNotExist terms, which remove"
                " Services from a set nothing bounded -- so it serves every LoadBalancer"
                " Service those terms do not name")
    return None

def selector_verdict(selector, labels):
    """True, False, or a string saying why a render cannot answer the question.

    Cilium runs the pool's serviceSelector through LabelSelectorAsSelector and skips the
    pool when it does not match, so this is the same question LB-IPAM asks -- asked of
    the rendered Service instead of the live one.
    """
    if not isinstance(selector, dict):
        return f"spec.serviceSelector is {type(selector).__name__}, not a mapping"
    match_labels = selector.get("matchLabels") or {}
    expressions = selector.get("matchExpressions") or []
    if not isinstance(match_labels, dict) or not isinstance(expressions, list):
        return "spec.serviceSelector has a malformed matchLabels or matchExpressions"
    keys = list(match_labels) + [e.get("key") for e in expressions if isinstance(e, dict)]
    # The namespace is the one thing about this Service the render here does not know:
    # the loop above renders every chart without --namespace, so the Service arrives
    # stamped `default` while the play installs the chart into kube-system. Narrower than
    # name alone and refused anyway, because guessing either way would let this pass a
    # selector the cluster rejects, or fail one it accepts. Closing it means giving the
    # render loop a per-chart namespace, not a change here.
    if NAMESPACE_LABEL in keys:
        return (f"selects on {NAMESPACE_LABEL}, which this script's namespace-less render"
                f" cannot answer -- select on {NAME_LABEL} instead")
    if labels is None:
        return f"there is no rendered {INGRESS_SERVICE} Service to match it against"
    for key, value in match_labels.items():
        if labels.get(key) != label_value(value):
            return False
    for expr in expressions:
        if not isinstance(expr, dict) or "key" not in expr:
            return f"matchExpressions entry {expr!r} is malformed"
        key, operator = expr["key"], expr.get("operator")
        wanted = [label_value(v) for v in (expr.get("values") or [])]
        # Absent-key semantics are Kubernetes': In demands the key, NotIn is satisfied
        # without it.
        if operator == "In":
            if labels.get(key) not in wanted:
                return False
        elif operator == "NotIn":
            if labels.get(key) in wanted:
                return False
        elif operator == "Exists":
            if key not in labels:
                return False
        elif operator == "DoesNotExist":
            if key in labels:
                return False
        else:
            return (f"matchExpressions operator {operator!r} is not one of"
                    " In, NotIn, Exists, DoesNotExist")
    return True

# The pin comes out of the render rather than out of values.yaml, because a pin is only
# real if the Service carrying it is emitted at all: with ingressController.enabled
# false the annotation still reads perfectly and there is no shared entrypoint behind
# it. Match on kind and name, not namespace -- a bare `helm template` puts the Service
# in default, while the play installs the chart into kube-system.
#
# Read before the pools rather than after them: a pool's serviceSelector is a claim about
# this Service, and there is nothing to judge it against until its labels are in hand.
pin = None
svc_labels = None
other_services = {}   # every other Service in the render, by name, with the labels a pool
                      # selector is matched against
try:
    docs = [d for d in yaml.safe_load_all(render.read_text()) if isinstance(d, dict)]
except (OSError, yaml.YAMLError) as exc:
    docs = []
    errors.append(f"the cilium render could not be read: {exc}")
services = [d for d in docs
            if d.get("kind") == "Service"
            and (d.get("metadata") or {}).get("name") == INGRESS_SERVICE]
if not docs:
    errors.append(f"the cilium chart rendered nothing -- {chart} is where the ingress"
                  " Service comes from")
elif not services:
    errors.append(f"the cilium render has no {INGRESS_SERVICE} Service, so nothing carries"
                  f" the pin -- check cilium.ingressController.enabled in {values}")
else:
    annotations = {}
    labels = {}
    for service in services:
        metadata = service.get("metadata") or {}
        annotations.update(metadata.get("annotations") or {})
        labels.update(metadata.get("labels") or {})
    labels[NAME_LABEL] = INGRESS_SERVICE
    svc_labels = {k: label_value(v) for k, v in labels.items()}
    # The rest of the render's Services, labelled the same way, so a selector that claims
    # to reserve an address for the ingress can be asked whether it also matches something
    # else. Every Service, not only the LoadBalancers: see the pool loop.
    for doc in docs:
        metadata = doc.get("metadata") or {}
        name = metadata.get("name")
        if doc.get("kind") != "Service" or name == INGRESS_SERVICE or not name:
            continue
        other = {k: label_value(v) for k, v in (metadata.get("labels") or {}).items()}
        other[NAME_LABEL] = name
        other_services[name] = other
    pin = annotations.get("lbipam.cilium.io/ips")
    if not pin:
        # Not merely cosmetic, and not a vacuous pass to skip over: unpinned, the shared
        # entrypoint takes whatever LB-IPAM hands out and the ingress A records rot. A
        # misspelled annotation key looks exactly like this, and Kubernetes accepts it.
        errors.append("the rendered cilium-ingress Service carries no lbipam.cilium.io/ips"
                      f" -- set it in {values}")

# *.y*ml, not *.yaml: ArgoCD's directory sync applies both spellings, and reading only
# half the pools would let a pin look homeless when it is not, or let a pool that can give
# the address away go unseen.
#
# Read once and scanned twice below, rather than globbed once per kind: the two
# passes would otherwise each need their own copy of this read-error handling, and a
# manifest that parsed for one and not the other is not a state worth having.
config_docs = []
for path in sorted(config_dir.glob("*.y*ml")):
    try:
        config_docs += [(path, d) for d in yaml.safe_load_all(path.read_text())
                        if isinstance(d, dict)]
    except (OSError, yaml.YAMLError) as exc:
        errors.append(f"{path} could not be read: {exc}")

for path, doc in config_docs:
    if doc.get("kind") != "CiliumLoadBalancerIPPool":
        continue
    name = (doc.get("metadata") or {}).get("name") or path.name
    spec = doc.get("spec") or {}
    # `live` is what the pin questions weigh; every block is recorded either way, because
    # the overlap check at the end is Cilium's conflict pass and that reads neither
    # spec.disabled nor spec.serviceSelector.
    #
    # A pool that cannot hand this service an address is not containment, however well its
    # blocks cover the pin. spec.disabled takes the whole pool out of service, so it is
    # neither containment nor a threat to it -- named in the failure rather than passed
    # over in silence, because an operator who meant it to serve the ingress is owed the
    # reason it did not count.
    live, serves_ingress, reserved = True, True, False
    also_matches = []
    disabled = bool(spec.get("disabled"))
    open_reason = "has no serviceSelector and so serves every LoadBalancer Service"
    selector = spec.get("serviceSelector")
    if disabled:
        skipped.append(f"{name} (disabled)")
        live, serves_ingress = False, False
    # spec.serviceSelector narrows a pool to the Services it matches, which is both how a
    # pool can fail to serve the ingress and how it can be reserved for it. This used to
    # refuse the question outright -- the ingress Service's labels being the upstream
    # chart's to set, not this repo's -- and that refusal is what made a reservation
    # uncheckable. The render answers it: the labels matched are the ones the pinned chart
    # version actually emits, so a chart that renames them turns this red rather than
    # turning the reservation into a fiction.
    #
    # `is not None`, not truthiness: `serviceSelector: {}` is a selector -- Cilium's
    # match-all, so not a narrowing and not a reservation -- and skipping the branch on it
    # would leave the failure below describing a file that has no such line in it.
    elif selector is not None:
        verdict = selector_verdict(selector, svc_labels)
        if isinstance(verdict, str):
            skipped.append(f"{name} (serviceSelector {verdict})")
            live, serves_ingress = False, False
        else:
            if not verdict:
                skipped.append(f"{name} (serviceSelector does not match the rendered"
                               f" {INGRESS_SERVICE} Service)")
            # Matching the ingress is not enough to be a reservation: the selector also
            # has to bound what else it can match. Both ways of failing that are the same
            # failure for the pin, so they share the message below and differ only in the
            # clause selector_bounds hands back.
            bounds = selector_bounds(selector)
            if bounds:
                open_reason = bounds
            serves_ingress, reserved = verdict, verdict and bounds is None
            # Whether the selector that reserves an address also matches something else.
            # "Does this match more than one Service in the cluster" is not a question a
            # check over files can answer; "does it also match another Service in this
            # render" is, and it is one-sided in the safe direction -- it cannot prove a
            # selector narrow, but it can prove one broad, which is the direction that
            # turns a reservation into a fiction. app.kubernetes.io/part-of=cilium is on
            # all three Services this chart renders and reads exactly like a reservation
            # until something asks.
            #
            # Every Service in the render, not only the LoadBalancers: cilium-envoy and
            # hubble-peer take nothing from the ingress today because nothing allocates
            # them an address. A selector that names something other than the ingress is
            # worth failing on before an upstream chart turns one of them into a
            # LoadBalancer, not after.
            if reserved:
                also_matches = sorted(name for name, other in other_services.items()
                                      if selector_verdict(selector, other) is True)
    # Quoted "No" arrives as a string, bare No as False -- the field is a string
    # enum, but nothing stops the YAML from being written either way.
    allow_first_last = str(spec.get("allowFirstLastIPs", "Yes")).lower() not in ("no", "false")
    for index, block in enumerate(spec.get("blocks") or []):
        try:
            label, first, last, span_first, span_last = parse_block(name, block, allow_first_last)
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"{name} block {index} is malformed ({exc}): {block!r}")
            continue
        blocks.append({"pool": name, "label": label, "first": first, "last": last,
                       "span": (span_first, span_last), "live": live,
                       "serves_ingress": serves_ingress, "reserved": reserved,
                       "also_matches": also_matches, "disabled": disabled,
                       "open_reason": open_reason})

# What announces those addresses. loadBalancerIPs is the field that matters: a policy
# with externalIPs alone covers Service.spec.externalIPs, which nothing in this repo
# sets, and covers nothing LB-IPAM hands out -- so it is not an announcer for the pool
# however well-formed it is.
#
# spec.interfaces is not read here. It is a list of regular expressions matched against
# interface names, and absent or empty means every interface, so there is no value it
# could hold that this could call wrong without knowing the host's NICs. Nor is
# nodeSelector or serviceSelector: both decide whether a policy announces, not where,
# and guessing at label matches against a Service whose labels the upstream chart sets
# is how a check starts failing on correct configuration.
announcers = [(doc.get("metadata") or {}).get("name") or path.name
              for path, doc in config_docs
              if doc.get("kind") == "CiliumL2AnnouncementPolicy"
              and (doc.get("spec") or {}).get("loadBalancerIPs")]
if not announcers:
    policies = [(doc.get("metadata") or {}).get("name") or path.name
                for path, doc in config_docs
                if doc.get("kind") == "CiliumL2AnnouncementPolicy"]
    detail = (f" -- the policies there ({', '.join(policies)}) do not set it"
              if policies else "")
    errors.append("no CiliumL2AnnouncementPolicy under"
                  f" {config_dir} sets loadBalancerIPs: true{detail}. The pool"
                  " above still allocates and cilium-ingress still gets an EXTERNAL-IP,"
                  " so the cluster reports nothing wrong; the address simply answers no"
                  " ARP and nothing on the LAN can reach any Ingress")

# The pools against each other, before the pin against the pools. Cilium settles an
# overlap by marking one of the two pools Conflicting and internally disabling every range
# it holds -- "Mark all ranges of the pool as internally disabled so we will not allocate
# from them" -- so an overlap does not trim the pools involved, it switches one off. Which
# one is the newer by CreationTimestamp, and nothing in git says which that will be: from
# here it could be the pool holding the pin, and then the pinned address is served by
# nobody and every Ingress is dead.
#
# Every block counts, including the ones the pin questions skip: settleConflicts reads
# neither spec.disabled nor spec.serviceSelector, only whether two ranges intersect
# (operator/pkg/lbipam/range_store.go). Two blocks of one pool are the same failure by a
# different route -- areRangesInternallyConflicting marks that pool on its own -- so pairs
# from one pool are checked too, and the message says which case it is.
def overlap_label(block):
    first, last = block["span"]
    # Named, because an operator who disabled a pool on purpose and is then told it
    # conflicts will otherwise go looking for the reason in the wrong place.
    disabled = " [spec.disabled, which the conflict pass does not exempt]" if block["disabled"] else ""
    if (first, last) == (block["first"], block["last"]):
        return block["label"] + disabled
    # allowFirstLastIPs withheld the ends of this CIDR, so the label spells a narrower
    # range than the one that conflicts. Say both, or an overlap reported at an address
    # outside the block it names reads as a broken checker.
    return f"{block['label']} [whole range {first}-{last}]" + disabled

for index, one in enumerate(blocks):
    for two in blocks[index + 1:]:
        (one_first, one_last), (two_first, two_last) = one["span"], two["span"]
        if one_first.version != two_first.version:
            continue
        if one_last < two_first or two_last < one_first:
            continue
        shared_first, shared_last = max(one_first, two_first), min(one_last, two_last)
        shared = (f"{shared_first}" if shared_first == shared_last
                  else f"{shared_first}-{shared_last}")
        if one["pool"] == two["pool"]:
            consequence = ("Two blocks of one pool: Cilium marks it internally conflicting"
                           " and disables every range it has, so the whole pool stops"
                           " serving")
        else:
            consequence = ("Cilium marks the newer of the two pools -- by"
                           " CreationTimestamp, which is not in git, so this cannot say"
                           " which -- Conflicting and internally disables every range it"
                           " has. If that is the pool holding the ingress pin, the pin is"
                           " served by nobody and every Ingress in the cluster is dead"
                           " (#69)")
        errors.append(f"pool blocks {overlap_label(one)} and {overlap_label(two)} overlap"
                      f" on {shared}. {consequence}")

servable = [b for b in blocks if b["live"] and b["serves_ingress"]]
if not servable:
    detail = f" (skipped {', '.join(skipped)})" if skipped else ""
    errors.append(f"no usable CiliumLoadBalancerIPPool block found under {config_dir}{detail}")

for text in str(pin or "").split(","):
    text = text.strip()
    if not text:
        continue
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        errors.append(f"lbipam.cilium.io/ips value {text!r} is not an IP address"
                      " -- the annotation takes bare addresses, not CIDRs")
        continue
    covering = [b for b in blocks if b["live"]
                and b["first"].version == ip.version and b["first"] <= ip <= b["last"]]
    # `servable` empty is already its own failure above -- saying the pin is outside a
    # pool that does not exist on top of it just buries the reason.
    if servable and not any(b["serves_ingress"] for b in covering):
        detail = f"; skipped {', '.join(skipped)}" if skipped else ""
        spelled = ", ".join(b["label"] for b in servable)
        errors.append(f"ingress pin {ip} is outside every pool block that can serve it"
                      f" ({spelled}){detail}")
    for block in covering:
        label, open_reason = block["label"], block["open_reason"]
        if block["reserved"]:
            if block["also_matches"]:
                errors.append(
                    f"ingress pin {ip} is inside {label}, whose serviceSelector matches"
                    f" {', '.join(block['also_matches'])} in the cilium render as well as"
                    f" {INGRESS_SERVICE} -- so it reserves the address for a set of"
                    " Services, not for the shared entrypoint, and any of them that"
                    " becomes a LoadBalancer can be handed the pin (#69). Select on"
                    f" {NAME_LABEL}, or on a label only {INGRESS_SERVICE} carries.")
            continue
        if block["serves_ingress"]:
            errors.append(
                f"ingress pin {ip} is inside {label}, which {open_reason}. LB-IPAM can hand"
                " that address to the next Service that asks for one, and will not evict it"
                " to satisfy the pin -- cilium-ingress then sits at"
                " IPAMRequestSatisfied=False with every Ingress in the cluster dead (#69)."
                " Reserve the pin in a pool whose serviceSelector names"
                f" {INGRESS_SERVICE} positively, and keep the general pool clear of it.")
        else:
            errors.append(
                f"ingress pin {ip} is inside {label}, whose serviceSelector does not match"
                f" the {INGRESS_SERVICE} Service -- the address is reserved for something"
                " else, which can take it and will not be evicted to satisfy the pin (#69)")

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

# The GPU invariant, and the second cross-file pair in this repo. The GPU Operator's
# ClusterPolicy is where it is told which parts of the stack it owns, and two of those
# answers are only correct relative to what the *playbook* does -- which the chart cannot
# see and ArgoCD never reads.
#
# Asserted against the render rather than against values.yaml, because a value only matters
# if it reaches the ClusterPolicy: a key nested wrong, or one the chart has since renamed,
# reads perfectly in values.yaml and silently leaves the default in force. The ClusterPolicy
# is what the operator actually acts on.
#
# Each of these fails late and confusingly without this check. driver.enabled would have the
# Operator build a kernel module against a driver the play just asserted is already there;
# toolkit.enabled off means nothing configures containerd at all, since the play
# deliberately does not; devicePlugin.enabled off means the play's own gate waits twenty
# minutes for a resource nothing will ever publish.
echo "==> $gpu_dir (ClusterPolicy)"
if gpu_errors=$(GPU_DIR="$gpu_dir" GPU_RENDER="$gpu_render" python3 - 2>&1 <<'GPUPY'
import os, pathlib, sys, yaml

chart = os.environ["GPU_DIR"]
render = pathlib.Path(os.environ["GPU_RENDER"])

errors = []
try:
    docs = [d for d in yaml.safe_load_all(render.read_text()) if isinstance(d, dict)]
except (OSError, yaml.YAMLError) as exc:
    docs = []
    errors.append(f"the {chart} render could not be read: {exc}")

if not docs:
    errors.append(f"{chart} rendered nothing -- that chart is the whole GPU stack, and"
                  " without it no model server can ever be scheduled")

policies = [d for d in docs if d.get("kind") == "ClusterPolicy"]
if docs and len(policies) != 1:
    # The play's gate reads `kubectl get clusterpolicy` across all items; more than one
    # would make that ambiguous, and none means nothing drives the operator at all.
    errors.append(f"the {chart} render has {len(policies)} ClusterPolicy resources, and the"
                  " playbook's GPU gate assumes exactly one")

# (key path, required value, why)
REQUIRED = [
    (("driver", "enabled"), False,
     "the playbook asserts a working host driver before it touches the machine, and the"
     " Operator's driver component would build a second one as a container against the"
     " same kernel"),
    (("toolkit", "enabled"), True,
     "the playbook deliberately configures nothing about containerd for GPUs -- the"
     " Operator is the single writer of the runtime handler, and with this off there is"
     " no writer at all"),
    (("devicePlugin", "enabled"), True,
     "it is what publishes nvidia.com/gpu, which the playbook's own gate waits twenty"
     " minutes for before failing"),
]
for policy in policies:
    spec = policy.get("spec") or {}
    for path, required, why in REQUIRED:
        component = spec.get(path[0])
        actual = component.get(path[1]) if isinstance(component, dict) else None
        if actual is not required:
            errors.append(f"ClusterPolicy spec.{'.'.join(path)} is {actual!r}, must be"
                          f" {required!r} -- {why}")

print("\n".join(errors))
sys.exit(1 if errors else 0)
GPUPY
); then
  echo "    ok"
else
  while IFS= read -r line; do
    echo "    FAIL: $line"
  done <<<"$gpu_errors"
  fail=1
fi

# The apt-source ordering invariant in playbook.yml -- a cross-file-shaped problem living
# inside one file: an ordering relationship between two tasks hundreds of lines apart,
# where neither looks wrong on its own.
#
# `gpg --dearmor` writes the Kubernetes keyring 0600 and apt runs gpgv as the unprivileged
# `_apt`, so until the mode task has run the repository verifies as unsigned. An apt
# refresh validates EVERY configured source, so any `update_cache: true` that runs before
# that task takes the whole play down -- and re-running cannot fix it, because the repair
# is downstream of the thing that fails. Three separate attempts at this each moved the
# error earlier in the play rather than removing it, which is what makes it worth a check
# rather than a comment.
echo "==> infrastructure/k8s-ansible/playbook.yml"
if apt_order_errors=$(python3 - 2>&1 <<'APTPY'
import pathlib, re, sys

lines = pathlib.Path("infrastructure/k8s-ansible/playbook.yml").read_text().splitlines()
REPAIR = "Make the Kubernetes apt key readable by _apt"

repair = [i for i, l in enumerate(lines, 1)
          if re.match(r"\s*- name:\s*" + re.escape(REPAIR) + r"\s*$", l)]
# Two spellings, because a check that only knows one is a check that a future edit walks
# past. YAML's booleans are not just `true` -- Ansible accepts yes/on/True/YES equally --
# and the module can also be written inline as `apt: name=curl update_cache=yes`, which is
# exactly the terser form someone reaches for when adding a quick task. Nothing in this
# repo uses the inline spelling today; it is here so that "today" is not load-bearing.
#
# What this still cannot see, stated so the check is honest about its own reach: a value
# supplied by a variable (`update_cache: "{{ refresh }}"`), a refresh performed by
# something other than the apt module (`command: apt-get update`, `apt_repository` with
# update_cache), and anything in a file this does not read, since the play is a single
# file with no includes. Each would need a different check; none is reachable by grep.
#
# Comment lines are skipped, and that is not cosmetic. The colon branch is anchored
# (`match` ... `$`), so prose cannot trip it; the inline branch has to be an unanchored
# `search` to find `update_cache=yes` mid-line, which means a comment *mentioning* the
# inline spelling matches. The apt-sources block in that play is several paragraphs of
# prose about update_cache, so the failure a maintainer hits is: document the inline form
# above the repair task -- exactly what the comment here suggests someone might do -- and
# CI goes red asserting an ordering bug that does not exist. A check whose message is a
# confident description of a specific bug has to be right about it.
BOOL = r"(true|yes|on)"
# Three spellings, because the anchored block form alone missed the one this repo is most
# likely to write. `\s*$` means any trailing content breaks the match -- including the
# trailing annotation nearly every setting in this play carries:
#
#     update_cache: true  # make sure the lists are fresh     <- passed green
#
# That is a real task, ahead of the repair, reintroducing the exact bug this check exists
# for. An optional trailing comment closes it, and it is safe to anchor that loosely here
# because the value is a boolean: there is no quoted string that could legitimately hold a
# `#`, which is the usual reason not to split YAML on one.
#
# The third branch is the flow-mapping spelling (`apt: {name: foo, update_cache: true}`),
# which the anchored form cannot see either. It requires the mapping punctuation on both
# sides, so it cannot match prose even if the comment skip above ever stopped applying.
#
# Still not seen, so the check's reach stays documented rather than assumed: a value
# supplied by a variable (`update_cache: "{{ refresh }}"`), a refresh performed by
# something other than the apt module (`command: apt-get update`, `apt_repository`), and
# anything outside this one file, since the play has no includes.
BLOCK  = r"\s*update_cache:\s*" + BOOL + r"\s*(#.*)?$"
INLINE = r"\bupdate_cache\s*=\s*" + BOOL + r"\b"
FLOW   = r"[{,]\s*update_cache\s*:\s*" + BOOL + r"\s*[,}]"
refresh = [i for i, l in enumerate(lines, 1)
           if not l.lstrip().startswith("#")
           and (re.match(BLOCK, l, re.I)
                or re.search(INLINE, l, re.I)
                or re.search(FLOW, l, re.I))]

errors = []
if not repair:
    errors.append("no task named %r -- the keyring is never made readable by _apt, so"
                  " every apt refresh rejects the Kubernetes repo as unsigned" % REPAIR)
elif len(repair) > 1:
    errors.append("%r appears %d times (lines %s); this check assumes one"
                  % (REPAIR, len(repair), repair))
else:
    early = [n for n in refresh if n < repair[0]]
    if early:
        errors.append(
            "an apt cache refresh at line(s) %s runs before %r at line %d. An apt refresh"
            " validates every configured repository, so on any machine that already has"
            " kubernetes.list this fails before the play can repair the keyring -- and"
            " re-running cannot help. Move the apt-source block ahead of the first"
            " refresh, or drop update_cache from the earlier task."
            % (early, REPAIR, repair[0]))

print("\n".join(errors))
sys.exit(1 if errors else 0)
APTPY
); then
  echo "    ok"
else
  while IFS= read -r line; do
    echo "    FAIL: $line"
  done <<<"$apt_order_errors"
  fail=1
fi

exit "$fail"
