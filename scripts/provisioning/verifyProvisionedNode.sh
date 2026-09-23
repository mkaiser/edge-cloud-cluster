#!/bin/bash
# verifyProvisionedNode.sh — check that ONE node came out of provisioning + adoption complete.
#
# Answers "did it actually work?" after provision-mesh-node-local.sh + adoptProvisionedNodes.sh.
# Read-only: it inspects, never changes anything.
#
# Checks the things that fail SILENTLY — a node can sit Ready for days while holding no
# replicas and running no pods:
#   - k8s node Ready, ROLE mesh, the ecc/mesh taint
#   - the ecc/* labels adoption is supposed to set
#   - storageScope vs. the LIVE Longhorn disk tags (the annotation alone is not enough —
#     Longhorn reads it only when it first creates the disk, which on the manual path has
#     already happened by the time adoption runs)
#   - a matching longhorn-<scope> StorageClass exists for each tag
#   - nested-runtime label vs. a RuntimeClass that actually targets this node
#   - the tailnet entry and its tag:k8s-node
#
# Usage:
#   bash scripts/provisioning/verifyProvisionedNode.sh <node-name>
set -uo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "Usage: $0 <node-name>" >&2; exit 2; }

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ] \
   && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  R=$(tput sgr0); GRN=$(tput setaf 2); RED=$(tput setaf 1); YEL=$(tput setaf 3); B=$(tput bold)
else R=""; GRN=""; RED=""; YEL=""; B=""; fi

FAIL=0
ok()   { echo "  ${GRN}✔${R} $*"; }
bad()  { echo "  ${RED}✗${R} $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ${YEL}!${R} $*"; }

kubectl get node "$NAME" >/dev/null 2>&1 || { echo "ERROR: no such k8s node '$NAME'." >&2; exit 1; }
NODE_JSON=$(kubectl get node "$NAME" -o json)
lbl() { echo "$NODE_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['metadata']['labels'].get('$1',''))"; }
ann() { echo "$NODE_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['metadata'].get('annotations',{}).get('$1',''))"; }

echo ""
echo "${B}Verifying node: $NAME${R}"

echo ""
echo "${B}k8s${R}"
READY=$(echo "$NODE_JSON" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['type']=='Ready': print(c['status'])")
[ "$READY" = "True" ] && ok "Ready" || bad "not Ready (status=$READY)"

# node-role labels are VALUELESS (key present, value ""), so test key PRESENCE — `lbl` would
# return "" for both "absent" and "present but empty" and always report it missing.
HAS_MESH_ROLE=$(echo "$NODE_JSON" | python3 -c "
import json,sys
print('node-role.kubernetes.io/mesh' in json.load(sys.stdin)['metadata']['labels'])")
[ "$HAS_MESH_ROLE" = "True" ] && ok "ROLE mesh" \
  || bad "missing node-role.kubernetes.io/mesh — 40-join-cluster.sh did not label it"

TAINTS=$(echo "$NODE_JSON" | python3 -c "
import json,sys
print(','.join(f\"{t['key']}={t.get('value')}:{t['effect']}\" for t in (json.load(sys.stdin)['spec'].get('taints') or [])))")
case "$TAINTS" in
  *ecc/mesh=true:NoSchedule*) ok "taint ecc/mesh=true:NoSchedule" ;;
  *) bad "missing ecc/mesh taint (cloud workloads could land here); taints=[$TAINTS]" ;;
esac

echo ""
echo "${B}adoption labels${R}"
SITE=$(lbl ecc/site)
[ -n "$SITE" ] && ok "ecc/site=$SITE" || bad "no ecc/site — adoption did not run"
[ -n "$(lbl ecc/kvm)" ]         && ok "ecc/kvm=$(lbl ecc/kvm)"                 || warn "no ecc/kvm (fine if not KVM-capable)"
[ -n "$(lbl ecc/gpu)" ]         && ok "ecc/gpu=$(lbl ecc/gpu) model=$(lbl ecc/gpu-model)" || warn "no ecc/gpu (fine if no GPU)"
[ -n "$(lbl ecc/eda-builder)" ] && ok "ecc/eda-builder=$(lbl ecc/eda-builder)" || true
[ -n "$(ann ecc/description)" ] && ok "description: $(ann ecc/description)"     || true

FP=$(ann ecc/provision-fingerprint)
if [ -n "$FP" ]; then ok "provision-fingerprint=$FP"
else warn "no ecc/provision-fingerprint — 'make provision-mesh-node' will NOT skip this node"
     warn "  (expected when the node is not declared in project_settings.ts nodes.mesh[])"
fi

echo ""
echo "${B}storage${R}"
LH=$(kubectl get nodes.longhorn.io -n longhorn-system "$NAME" -o json 2>/dev/null)
if [ -z "$LH" ]; then
  bad "no Longhorn node CR — this node backs no volumes"
else
  DISK_TAGS=$(echo "$LH" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=set()
for disk in d.get('spec',{}).get('disks',{}).values(): t.update(disk.get('tags') or [])
print(','.join(sorted(t)))")
  # The UNION across every declared disk, not just [0]. A node may declare extra Longhorn
  # disks (project_settings extraLonghornDisks), and DISK_TAGS above already unions the live
  # ones — reading only the first entry here made the two sides incomparable, so any
  # multi-disk node reported a spurious "disk tags != intended".
  WANT=$(ann node.longhorn.io/default-disks-config | python3 -c "
import json,sys
try:
    t=set()
    for d in json.load(sys.stdin): t.update(d.get('tags') or [])
    print(','.join(sorted(t)))
except Exception: print('')" 2>/dev/null)

  SCHED=$(echo "$LH" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(all(x.get('allowScheduling') for x in d.get('spec',{}).get('disks',{}).values()))")
  [ "$SCHED" = "True" ] && ok "disk allowScheduling=true" || bad "disk has allowScheduling=false — holds no replicas"

  if [ -z "$DISK_TAGS" ]; then
    bad "Longhorn disk has NO tags — node backs no longhorn-<scope> StorageClass"
  elif [ -n "$WANT" ] && [ "$DISK_TAGS" != "$WANT" ]; then
    bad "disk tags [$DISK_TAGS] != intended [$WANT]"
    warn "  Longhorn reads the annotation only when it FIRST creates the disk; re-run"
    warn "  adoptProvisionedNodes.sh (it now patches the live CR) or fix it in the Longhorn UI."
  else
    ok "Longhorn disk tags [$DISK_TAGS]"
  fi

  IFS=',' read -ra TAGS <<< "$DISK_TAGS"
  for t in "${TAGS[@]}"; do
    [ -n "$t" ] || continue
    if kubectl get sc "longhorn-$t" >/dev/null 2>&1; then ok "StorageClass longhorn-$t exists"
    else bad "no StorageClass longhorn-$t — nothing can request this scope"; fi
  done

  if [ -n "$SITE" ] && [ -n "$DISK_TAGS" ]; then
    case ",$DISK_TAGS," in
      *",$SITE,"*) : ;;
      *) warn "no scope matches ecc/site=$SITE — intended? a scope shared with another"
         warn "  site means cross-LAN replication over WireGuard." ;;
    esac
  fi
fi

echo ""
echo "${B}nested runtime${R}"
NESTED=$(lbl ecc/nested-runtime)
if [ -z "$NESTED" ]; then
  warn "no ecc/nested-runtime (fine if the node was provisioned without one)"
else
  ok "ecc/nested-runtime=$NESTED"
  RC=$(kubectl get runtimeclass -o json | NESTED="$NESTED" python3 -c "
import json,os,sys
want=os.environ['NESTED']
for rc in json.load(sys.stdin)['items']:
    sel=(rc.get('scheduling') or {}).get('nodeSelector') or {}
    if any(k.startswith('ecc/nested-runtime') for k in sel) and (want in rc['metadata']['name'] or want in rc.get('handler','') or rc.get('handler')=='runsc'):
        print(rc['metadata']['name']); break")
  if [ -n "$RC" ]; then
    ok "RuntimeClass '$RC' targets this node"
    echo "     smoke-test it:  kubectl run rt-check --image=busybox:1.36 --restart=Never \\"
    echo "       --overrides='{\"spec\":{\"runtimeClassName\":\"$RC\",\"nodeName\":\"$NAME\",\"tolerations\":[{\"key\":\"ecc/mesh\",\"operator\":\"Equal\",\"value\":\"true\",\"effect\":\"NoSchedule\"}]}}' \\"
    echo "       -- sh -c 'dmesg | head -1'"
  else
    bad "no RuntimeClass selects ecc/nested-runtime — pods using it will hang in ContainerCreating"
  fi
fi

echo ""
echo "${B}tailnet${R}"
HS_POD=$(kubectl get pods -n headscale -l app.kubernetes.io/name=headscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$HS_POD" ] || HS_POD=$(kubectl get pods -n headscale -l app=headscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$HS_POD" ]; then
  warn "headscale pod not found — skipped"
else
  kubectl exec -n headscale "$HS_POD" -- headscale nodes list -o json 2>/dev/null \
  | NODE="$NAME" python3 -c "
import json,os,sys
want=os.environ['NODE']
try: nodes=json.load(sys.stdin)
except Exception: sys.exit(0)
hit=[n for n in nodes if n.get('name')==want or n.get('given_name')==want]
if not hit:
    print('MISSING'); sys.exit(0)
n=hit[0]
print('FOUND', n.get('id'), 'online' if n.get('online') else 'OFFLINE', ','.join(n.get('tags') or []) or 'NOTAGS')
dupes=[x.get('given_name') for x in nodes if str(x.get('given_name','')).startswith(want+'-')]
if dupes: print('DUPES', ','.join(dupes))
" | while read -r kind a b c; do
    case "$kind" in
      MISSING) bad "no tailnet entry named '$NAME'" ;;
      FOUND)
        [ "$b" = "online" ] && ok "tailnet node $a online" || bad "tailnet node $a is OFFLINE"
        if [ "$c" = "NOTAGS" ]; then
          bad "untagged — matches no tag-based ACL grant; re-run adoptProvisionedNodes.sh"
        else ok "tags: $c"; fi ;;
      DUPES) warn "stale duplicate tailnet entries: $a — clear with 'make prune-orphaned-mesh-nodes'" ;;
    esac
  done
fi

echo ""
echo "${B}scheduling${R}"
PODS=$(kubectl get pods -A --field-selector "spec.nodeName=$NAME" --no-headers 2>/dev/null | wc -l)
echo "  $PODS pod(s) currently on this node"

echo ""
if [ "$FAIL" -eq 0 ]; then echo "${GRN}${B}PASS${R} — $NAME looks fully provisioned."; exit 0
else echo "${RED}${B}$FAIL check(s) failed${R} — see above."; exit 1; fi
