#!/bin/bash
# Generate + seal every credential the ryax-engine chart would otherwise create
# itself. Run once per cluster; commit the sealed output.
#
# WHY THIS EXISTS
# The chart renders its credentials as `lookup(...) | default (randAlphaNum 12)`.
# `lookup()` needs a cluster connection, and ArgoCD's repo server renders with
# `helm template`, which has none -- so every reconcile mints NEW passwords and
# pushes them to running pods. Measured 2026-09-10: a resync rotated
# ryax-{datastore,broker,minio}-secret and four pods went CrashLoopBackOff with
# "password authentication failed for user runner" / "invalid credentials".
#
# ⚠ `ignoreDifferences` on Secret `.data` does NOT prevent this. It was configured
# on the live Application and the rotation happened anyway: it suppresses drift
# DETECTION, not a sync that is actively applying the rendered manifest.
#
# Supplying the secrets ourselves and setting `global.secrets.create: false` is
# upstream's documented GitOps path (docs/howto/install_ryax_argocd.md in
# gitlab.com/ryax-tech/ryax/ryax-engine): "with it, the chart renders
# byte-identically every time, so ArgoCD reports the app Synced and never
# rewrites a password."
#
# ⚠ THE CONNECTION URLS MUST AGREE WITH THE PASSWORDS IN THE SAME SECRET. The
# chart builds `datastore-<db>` and `broker` as URLs embedding the very password
# stored beside them, so these cannot be generated independently -- that is the
# whole reason this is a script and not thirteen kubectl invocations.
#
#   generateSecrets.sh            generate, seal, write ryax-secrets-sealed.yaml
#   generateSecrets.sh --dry-run  print what would be created, seal nothing
#
# ⚠ SEALS WITH THE STACK CERTIFICATE, never the live controller's. src/sealedsecrets.ts
# seeds each new cluster's controller from the Pulumi sealedSecretsTlsCrt/Key, so a file
# sealed against a RUNNING controller (kubeseal's default, which fetches the cert over the
# API) is openable only by that one cluster: it applies cleanly on the next one, produces NO
# Secret, and ryax comes up without credentials far from here. Measured 2026-09-10 — the two
# certs had already diverged and `make destroy`'s sealed-key preflight refused the teardown.
# This is why the seal below mirrors deployment/manageSealedSecrets.sh's `--cert` invocation.
#
# Needs kubeseal and a loaded Pulumi stack. A running controller is NOT required.
set -euo pipefail

NAMESPACE="ryaxns"
EXECS_NAMESPACE="ryaxns-execs"
APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
OUT="$APP_DIR/ryax-secrets-sealed.yaml"

# The Pulumi project root, found by walking UP for Pulumi.yaml rather than counting
# `../..` hops from APP_DIR. A fixed hop count silently breaks whenever this app moves
# between directory depths, and the symptom is a misleading "stack not loaded?" rather
# than a path error. Same approach as pulumi_root() in deployment/manageSealedSecrets.sh.
pulumi_root() {
  local d="$APP_DIR"
  while [ "$d" != "/" ]; do
    [ -f "$d/Pulumi.yaml" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  echo "ERROR: no Pulumi.yaml found above $APP_DIR" >&2
  return 1
}
PULUMI_DIR="$(pulumi_root)"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

command -v kubectl  >/dev/null || die "kubectl not found"
[ $DRY_RUN -eq 1 ] || command -v kubeseal >/dev/null || die "kubeseal not found"
# jq parses the unsealed ryax-user-credentials that Grafana's admin mirrors.
[ $DRY_RUN -eq 1 ] || command -v jq >/dev/null || die "jq not found"

# Fetched once, up front: sealing thirteen secrets against a cert that turns out to be
# unreadable would write a half-populated $OUT.
SEAL_CERT=""
if [ $DRY_RUN -eq 0 ]; then
  SEAL_CERT="$(cd "$PULUMI_DIR" && pulumi config get sealedSecretsTlsCrt 2>/dev/null || true)"
  [ -n "$SEAL_CERT" ] || die "sealedSecretsTlsCrt unreadable — run: source ./scripts/pulumi/initPulumiStack.sh"
fi

# The Ryax GUI account, sealed by sealSecrets.sh. Grafana's admin mirrors it (below), so its
# plaintext is recovered here with the stack's PRIVATE key -- the same offline unseal
# manageSealedSecrets.sh's try_recover does. No cluster contact, and no second copy of the
# password to drift.
USER_SEALED="$APP_DIR/ryax-user-credentials-sealed.yaml"
unseal_user_cred() {
  local key="$1" privkey
  [ -f "$USER_SEALED" ] || { echo ""; return; }
  privkey="$(cd "$PULUMI_DIR" && pulumi config get sealedSecretsTlsKey 2>/dev/null)" || { echo ""; return; }
  [ -n "$privkey" ] || { echo ""; return; }
  kubeseal --recovery-unseal --recovery-private-key <(printf '%s\n' "$privkey") \
      < "$USER_SEALED" -o json 2>/dev/null \
    | jq -r --arg k "$key" '.data[$k] // empty' \
    | base64 -d 2>/dev/null || true
}

# Chart defaults these all follow. Keep in step with the subchart values if a bump
# changes them: datastore.{datastoreUser,datastoreDB,databases},
# common-resources.{brokerUser,brokerService,brokerPort,filestoreUser,filestoreService,
# filestorePort}, registry.credentials.username.
DS_USER=ryax
DS_DB=ryaxdb
DS_SVC=ryax-datastore
DATABASES="repository studio authorization runner"
BROKER_USER=ryaxmq
BROKER_SVC=ryax-broker
BROKER_PORT=5672
FS_USER=ryax
FS_SVC=ryax-minio
FS_PORT=9000
REG_USER=ryax
REG_SVC=ryax-registry
REG_PORT=5000
# The kubelet pulls through the NodePort on its own loopback -- see
# the chart's ryax-registry-ext Service and worker-values.yaml's internalRegistryOverride.
REG_NODEPORT=30012

# alnum only: these end up inside postgresql:// and ampq:// URLs unescaped by the
# chart, so a '/', '@' or ':' in a password would silently corrupt the URL.
# ⚠ Read a fixed block and filter, rather than `tr -dc ... | head -c N`: under
# `set -o pipefail` head exits first, tr takes SIGPIPE, and the whole script dies
# with no message after the first password.
pw() { LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }
# Fernet keys are 32 raw bytes, base64'd -- the chart's own fallback is
# `randAscii 32 | b64enc`.
fernet() { head -c 32 /dev/urandom | base64 -w0; }

log "generating credentials ..."
DS_PASS="$(pw)"
BROKER_PASS="$(pw)"
BROKER_COOKIE="$(pw 30)"
FS_PASS="$(pw)"
JWT="$(pw 64)"
# Grafana's local admin deliberately MIRRORS the Ryax `ryax-user-credentials` account, so
# one login works for both the Ryax GUI and the /grafana tile it links to. Recovered from
# that sealed file rather than randomized, so re-running this script does not silently
# desync the two -- which is exactly what a `pw` call here would do.
GRAFANA_USER=""
GRAFANA_PASS=""
if [ $DRY_RUN -eq 0 ]; then
  GRAFANA_USER="$(unseal_user_cred username)"
  GRAFANA_PASS="$(unseal_user_cred password)"
  [ -n "$GRAFANA_USER" ] && [ -n "$GRAFANA_PASS" ] \
    || die "could not recover ryax-user-credentials — run sealSecrets.sh first (it creates $USER_SEALED)"
fi
REG_PASS="$(pw)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PLAIN="$TMP/plain.yaml"; : > "$PLAIN"

emit() { cat >> "$PLAIN"; }

# ── datastore ────────────────────────────────────────────────────────────────
{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "type: Opaque"
  echo "metadata:"
  echo "  name: ryax-datastore-secret"
  echo "  namespace: $NAMESPACE"
  echo "stringData:"
  echo "  datastore: postgresql://$DS_USER:$DS_PASS@$DS_SVC/$DS_DB"
  # monitoring.enabled adds this one; harmless when unused.
  echo "  all-databases: postgresql://$DS_USER:$DS_PASS@$DS_SVC/$DS_DB?sslmode=disable"
  echo "  datastore-db: $DS_DB"
  echo "  datastore-user: $DS_USER"
  echo "  datastore-pass: $DS_PASS"
  for db in $DATABASES; do
    p="$(pw)"
    echo "  datastore-$db: postgresql://$db:$p@$DS_SVC/$db"
    echo "  datastore-$db-db: $db"
    echo "  datastore-$db-user: $db"
    echo "  datastore-$db-pass: $p"
  done
  echo "---"
} | emit

# ── broker (release ns AND the exec ns) ──────────────────────────────────────
for ns in "$NAMESPACE" "$EXECS_NAMESPACE"; do
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "type: Opaque"
    echo "metadata:"
    echo "  name: ryax-broker-secret"
    echo "  namespace: $ns"
    echo "stringData:"
    echo "  broker-user: $BROKER_USER"
    echo "  broker: ampq://$BROKER_USER:$BROKER_PASS@$BROKER_SVC.$NAMESPACE:$BROKER_PORT/"
    echo "  rabbitmq-password: $BROKER_PASS"
    echo "---"
  } | emit
done

{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "type: Opaque"
  echo "metadata:"
  echo "  name: ryax-broker-cookie"
  echo "  namespace: $NAMESPACE"
  echo "stringData:"
  echo "  rabbitmq-erlang-cookie: $BROKER_COOKIE"
  echo "---"
} | emit

# ── filestore (minio) ────────────────────────────────────────────────────────
{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "type: Opaque"
  echo "metadata:"
  echo "  name: ryax-minio-secret"
  echo "  namespace: $NAMESPACE"
  echo "stringData:"
  echo "  filestore: $FS_SVC.$NAMESPACE:$FS_PORT"
  echo "  filestore-access: $FS_USER"
  echo "  filestore-secret: $FS_PASS"
  echo "  root-user: $FS_USER"
  echo "  root-password: $FS_PASS"
  echo "---"
} | emit

# ── single-key secrets ───────────────────────────────────────────────────────
one_key() { # name key value
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "type: Opaque"
    echo "metadata:"
    echo "  name: $1"
    echo "  namespace: $NAMESPACE"
    echo "stringData:"
    echo "  $2: $3"
    echo "---"
  } | emit
}
one_key api-jwt-secret-key                  jwt-secret-key "$JWT"
one_key runner-encryption-key               encryption-key "$(fernet)"
one_key studio-password-encryption-key      encryption-key "$(fernet)"
one_key repository-password-encryption-key  encryption-key "$(fernet)"

{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "type: Opaque"
  echo "metadata:"
  echo "  name: grafana-credentials"
  echo "  namespace: $NAMESPACE"
  echo "stringData:"
  echo "  admin-user: $GRAFANA_USER"
  echo "  admin-password: $GRAFANA_PASS"
  echo "---"
} | emit

# ── registry: htpasswd + a pull secret in BOTH namespaces ────────────────────
# ⚠ The pull secret is keyed BY REGISTRY HOST STRING, and two hosts reach the same
# registry: the in-cluster Service (pods push to it) and 127.0.0.1:30012 (the
# kubelet pulls through the NodePort). Both entries are required -- a pull from
# the loopback host with only the Service entry fails "no basic auth credentials".
command -v htpasswd >/dev/null \
  && HT="$(htpasswd -nbB "$REG_USER" "$REG_PASS")" \
  || HT="$(python3 -c '
import bcrypt,sys
print(sys.argv[1]+":"+bcrypt.hashpw(sys.argv[2].encode(),bcrypt.gensalt()).decode())
' "$REG_USER" "$REG_PASS" 2>/dev/null)" \
  || die "need either htpasswd (apache2-utils) or python3 with bcrypt"

one_key ryax-registry-credentials htpasswd "$HT"

AUTH_B64="$(printf '%s:%s' "$REG_USER" "$REG_PASS" | base64 -w0)"
DOCKERCFG="$(python3 -c '
import json,sys
h1,h2,a=sys.argv[1],sys.argv[2],sys.argv[3]
print(json.dumps({"auths":{h1:{"auth":a},h2:{"auth":a}}}))
' "127.0.0.1:$REG_NODEPORT" "$REG_SVC:$REG_PORT" "$AUTH_B64" | base64 -w0)"

for ns in "$NAMESPACE" "$EXECS_NAMESPACE"; do
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "type: kubernetes.io/dockerconfigjson"
    echo "metadata:"
    echo "  name: ryax-registry-creds-secret"
    echo "  namespace: $ns"
    echo "data:"
    echo "  .dockerconfigjson: $DOCKERCFG"
    echo "---"
  } | emit
done

COUNT="$(grep -c '^kind: Secret' "$PLAIN")"
log "built $COUNT secrets"

if [ $DRY_RUN -eq 1 ]; then
  grep -E '^  (name|namespace):' "$PLAIN" | paste - - | sed 's/^/  /'
  log "--dry-run: nothing sealed"
  exit 0
fi

log "sealing with kubeseal ..."
: > "$OUT"
{
  echo "# GENERATED by generateSecrets.sh — do not hand-edit."
  echo "#"
  echo "# Every credential the ryax-engine chart would otherwise generate itself."
  echo "# The chart is told not to (global.secrets.create: false in values.yaml)"
  echo "# because its lookup()-based generation mints new passwords on every ArgoCD"
  echo "# render and rotates them out from under running pods."
  echo "#"
  echo "# Re-run generateSecrets.sh to rotate. That changes the passwords, so the"
  echo "# datastore/broker/minio STATE must be wiped too — their servers keep the old"
  echo "# ones. See the script header."
} >> "$OUT"

csplit -z -f "$TMP/part" -b '%02d.yaml' "$PLAIN" '/^apiVersion: v1$/' '{*}' >/dev/null
for f in "$TMP"/part*.yaml; do
  sed -i '/^---$/d' "$f"
  [ -s "$f" ] || continue
  # --cert only: no --controller-* , so kubeseal never contacts a cluster.
  kubeseal --cert <(printf '%s\n' "$SEAL_CERT") \
           --format yaml < "$f" >> "$OUT"
  echo "---" >> "$OUT"
done

log "wrote $OUT ($(grep -c 'kind: SealedSecret' "$OUT") SealedSecrets)"
