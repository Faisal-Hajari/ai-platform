#!/usr/bin/env bash
# Renders every chart in this repo the way its deployer will and asserts the invariants
# that have bitten this cluster before. Run before pushing changes to either half -- a
# bad value here is accepted silently and only shows up later as a CrashLoop.
#
# Two halves, rendered identically because `helm template` is what both deployers do:
# infrastructure/k8s-ansible/system-apps/*/ is applied by the Ansible play (see
# system-apps/README.md), and deployment/*/*/ is synced by ArgoCD. deployment/ is empty
# today and that is not a failure -- the charts array below simply has one entry.
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
trap 'rm -f "$ingress_render"' EXIT

cilium_dir=infrastructure/k8s-ansible/system-apps/cilium

# Without nullglob an empty deployment/ hands the unexpanded pattern to helm, and the
# run ends on helm's complaint about a directory named `*` -- an error that says nothing
# about the invariants that went unchecked. Both patterns are globs for that reason,
# including the system-apps one, which today matches only $cilium_dir: a chart that has
# gone missing should reach the cross-file check below, which says what it was needed
# for, rather than take the run down on a helm error first.
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
# Two claims about that one address, and it needs both:
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
# Neither self-heals, and both halves are static YAML, so assert them here instead of
# learning them from the cluster. What exclusivity does not read is how *widely* a
# matching selector is drawn -- a pool selecting on a label other Services could also
# carry counts as a reservation here; io.kubernetes.service.name, which is what
# config/ip-pool.yaml selects on, is the narrowest form there is. Nor can it see a pool
# that exists in the cluster but not in git: `kubectl apply -f` has no prune, so one
# deleted or renamed here can outlive its manifest and go on handing out the pin.
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
    """(label, first address, last address), or ValueError if the block is malformed."""
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
        return f"{name}: {block['cidr']} ({first}-{last})", first, last
    # `stop` is optional to LB-IPAM: a block with a start and no stop is the single
    # address `start` (ipRangeFromBlock), which is the natural way to write a one-address
    # reservation. Requiring it here reported such a block as malformed.
    first = ipaddress.ip_address(block["start"])
    last = ipaddress.ip_address(block["stop"]) if block.get("stop") else first
    if last < first:
        raise ValueError(f"stop {last} precedes start {first}")
    if first == last:
        return f"{name}: {first}", first, last
    return f"{name}: {first}-{last}", first, last

def label_value(value):
    """A YAML scalar as Kubernetes would have stored the label value."""
    # Label values are strings, but nothing stops a selector being written with a bare
    # `true`, which YAML hands over as a bool -- and str(True) is "True", which matches
    # no label a chart ever writes.
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)

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
    # The namespace is the one thing about this Service a render does not know: `helm
    # template` stamps the release namespace -- default, here -- while the play installs
    # the chart into kube-system, which is why the lookup below matches on name and not
    # namespace. Guessing either way would let this pass a selector the cluster rejects,
    # or fail one it accepts, so refuse the question instead and say so.
    if NAMESPACE_LABEL in keys:
        return (f"selects on {NAMESPACE_LABEL}, which a `helm template` render cannot"
                f" answer -- select on {NAME_LABEL} instead")
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
    # A pool that cannot hand this service an address is not containment, however well
    # its blocks cover the pin. spec.disabled takes the whole pool out of service, so it
    # is neither containment nor a threat to it -- named in the failure rather than passed
    # over in silence, because an operator who meant it to serve the ingress is owed the
    # reason it did not count.
    if spec.get("disabled"):
        skipped.append(f"{name} (disabled)")
        continue
    # spec.serviceSelector narrows a pool to the Services it matches, which is both how a
    # pool can fail to serve the ingress and how it can be reserved for it. This used to
    # refuse the question outright -- the ingress Service's labels being the upstream
    # chart's to set, not this repo's -- and that refusal is what made a reservation
    # uncheckable. The render answers it: the labels matched are the ones the pinned chart
    # version actually emits, so a chart that renames them turns this red rather than
    # turning the reservation into a fiction.
    selector = spec.get("serviceSelector")
    serves_ingress, reserved = True, False
    open_reason = "has no serviceSelector"
    if selector:
        verdict = selector_verdict(selector, svc_labels)
        if isinstance(verdict, str):
            skipped.append(f"{name} (serviceSelector {verdict})")
            continue
        if not verdict:
            skipped.append(f"{name} (serviceSelector does not match the rendered"
                           f" {INGRESS_SERVICE} Service)")
        # An empty selector, or one whose matchLabels and matchExpressions are both empty,
        # is Cilium's match-all rather than a narrowing: it matches the ingress and
        # everything else too, so it reserves nothing.
        narrowing = bool((selector.get("matchLabels") or {})
                         or (selector.get("matchExpressions") or []))
        if not narrowing:
            open_reason = "has an empty serviceSelector, which Cilium reads as match-all,"
        serves_ingress, reserved = verdict, verdict and narrowing
    # Quoted "No" arrives as a string, bare No as False -- the field is a string
    # enum, but nothing stops the YAML from being written either way.
    allow_first_last = str(spec.get("allowFirstLastIPs", "Yes")).lower() not in ("no", "false")
    for index, block in enumerate(spec.get("blocks") or []):
        try:
            label, first, last = parse_block(name, block, allow_first_last)
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"{name} block {index} is malformed ({exc}): {block!r}")
            continue
        blocks.append((label, first, last, serves_ingress, reserved, open_reason))

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

servable = [b for b in blocks if b[3]]
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
    covering = [b for b in blocks if b[1].version == ip.version and b[1] <= ip <= b[2]]
    # `servable` empty is already its own failure above -- saying the pin is outside a
    # pool that does not exist on top of it just buries the reason.
    if servable and not any(serves for _, _, _, serves, _, _ in covering):
        detail = f"; skipped {', '.join(skipped)}" if skipped else ""
        spelled = ", ".join(label for label, _, _, serves, _, _ in blocks if serves)
        errors.append(f"ingress pin {ip} is outside every pool block that can serve it"
                      f" ({spelled}){detail}")
    for label, _, _, serves, reserved, open_reason in covering:
        if reserved:
            continue
        if serves:
            errors.append(
                f"ingress pin {ip} is inside {label}, which {open_reason} and so"
                " serves every LoadBalancer Service. LB-IPAM can hand that address to the"
                " next Service that asks for one, and will not evict it to satisfy the pin"
                " -- cilium-ingress then sits at IPAMRequestSatisfied=False with every"
                " Ingress in the cluster dead (#69). Reserve the pin in a pool whose"
                f" serviceSelector matches {INGRESS_SERVICE}, and keep the general pool"
                " clear of it.")
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
