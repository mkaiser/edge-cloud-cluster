#!/bin/bash
# Graceful cluster shutdown — preserves infrastructure and S3 data for later restore.
#
# Steps:
#   1. Ensure completeClusterTeardown=false in project_settings.ts
#   2. pulumi up (sync teardown flag to stack)
#   3. Trigger on-demand etcd snapshot to S3
#   4. Trigger Longhorn S3 backup for all volumes
#   5. Drain and cordon all nodes
#   6. pulumi dn (destroys servers/DNS/network, keeps S3 buckets)
#   7. Set restoreClusterFromS3Backup=true in project_settings.ts
#
# After this script: run 'make create' to restore the cluster from S3 backup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$SCRIPT_DIR/../project_settings.ts"

if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE; echo ""
    export PULUMI_CONFIG_PASSPHRASE
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster Shutdown — infrastructure preserved, data backed up      ║"
echo "║  Run 'make create' afterwards to restore from S3.                 ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
read -rp "Proceed with graceful shutdown? Type 'yes' to confirm: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Step 1: ensure completeClusterTeardown=false ───────────────────────────────
if grep -qE 'completeClusterTeardown\s*:\s*true' "$SETTINGS"; then
    echo ""
    echo "Setting completeClusterTeardown: false in project_settings.ts..."
    sed -i 's/completeClusterTeardown\s*:\s*true/completeClusterTeardown: false/' "$SETTINGS"
    echo "  Done."
else
    echo "completeClusterTeardown already false — no change needed."
fi

# ── Step 2: pulumi up (sync teardown flag to stack) ────────────────────────────
echo ""
echo "=== Step 2/7: pulumi up (sync stack) ==="
CI=true pulumi up -y

# ── Step 3: on-demand etcd snapshot to S3 ─────────────────────────────────────
echo ""
echo "=== Step 3/7: etcd on-demand snapshot → S3 ==="
# Run k3s etcd-snapshot save on the CP node via a privileged kubectl job.
# k3s reads S3 credentials from /etc/rancher/k3s/config.yaml automatically.
JOB_NAME="etcd-snapshot-$(date +%s)"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: kube-system
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 120
  template:
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      restartPolicy: Never
      volumes:
        - name: k3s-bin
          hostPath: { path: /usr/local/bin }
        - name: k3s-etc
          hostPath: { path: /etc/rancher/k3s }
        - name: k3s-data
          hostPath: { path: /var/lib/rancher/k3s }
        - name: tmp
          hostPath: { path: /tmp }
      containers:
        - name: snapshot
          image: alpine:3.20
          securityContext:
            privileged: true
          volumeMounts:
            - name: k3s-bin
              mountPath: /host-bin
            - name: k3s-etc
              mountPath: /etc/rancher/k3s
            - name: k3s-data
              mountPath: /var/lib/rancher/k3s
            - name: tmp
              mountPath: /tmp
          command: ["/bin/sh", "-c"]
          args:
            - |
              cp /host-bin/k3s /usr/local/bin/k3s
              echo "Creating on-demand etcd snapshot..."
              k3s etcd-snapshot save --name shutdown-snapshot
              echo "Snapshot saved."
EOF

echo "Waiting for etcd snapshot job to complete..."
kubectl wait --for=condition=complete job/"${JOB_NAME}" -n kube-system --timeout=120s \
    && echo "  Snapshot complete." \
    || { echo "  WARNING: snapshot job did not complete — check 'kubectl logs job/${JOB_NAME} -n kube-system'"; }

# ── Step 4: Longhorn backup ────────────────────────────────────────────────────
echo ""
echo "=== Step 4/7: Longhorn — trigger S3 backup for all volumes ==="
if kubectl get namespace longhorn-system >/dev/null 2>&1; then
    VOLUMES=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$VOLUMES" ]; then
        BACKUP_TARGET=$(kubectl get setting backup-target -n longhorn-system -o jsonpath='{.value}' 2>/dev/null || true)
        if [ -n "$BACKUP_TARGET" ] && [ "$BACKUP_TARGET" != "\"\"" ]; then
            echo "  Backup target: $BACKUP_TARGET"
            for VOL in $VOLUMES; do
                kubectl apply -f - <<BEOF 2>/dev/null || true
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: shutdown-${VOL}
  namespace: longhorn-system
spec:
  snapshotName: ""
  volumeName: ${VOL}
  labels:
    reason: shutdown
BEOF
                echo "  Triggered backup for volume: $VOL"
            done
            echo "  Longhorn backups triggered. They complete asynchronously."
            echo "  Check status: kubectl get backups.longhorn.io -n longhorn-system"
            echo ""
            read -rp "Wait 60s for Longhorn backups to start? [y/N]: " wait_longhorn
            if [[ "$wait_longhorn" =~ ^[Yy]$ ]]; then
                sleep 60
                kubectl get backups.longhorn.io -n longhorn-system 2>/dev/null | tail -10 || true
            fi
        else
            echo "  No S3 backup target configured in Longhorn — skipping."
        fi
    else
        echo "  No Longhorn volumes found — skipping."
    fi
else
    echo "  Longhorn not installed — skipping."
fi

# ── Step 5: drain all nodes ────────────────────────────────────────────────────
echo ""
echo "=== Step 5/7: Drain all cluster nodes ==="
NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for NODE in $NODES; do
    echo "  Draining $NODE..."
    kubectl drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=120s \
        2>/dev/null || echo "  WARNING: drain timed out for $NODE — continuing."
done
echo "  All nodes drained."

# ── Step 6: pulumi dn (tears down servers, keeps S3 since teardown=false) ─────
echo ""
echo "=== Step 6/7: pulumi dn (destroy servers, DNS, network — S3 buckets preserved) ==="
# Strip ArgoCD finalizers so the argocd namespace doesn't hang in Terminating.
if kubectl get namespace argocd >/dev/null 2>&1; then
    echo "  Stripping ArgoCD application finalizers..."
    kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null \
        | while read -r r; do
            kubectl patch "$r" -n argocd --type=merge \
                -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
          done
    kubectl delete applications.argoproj.io --all -n argocd \
        --force --grace-period=0 2>/dev/null || true
    echo "  Done."
fi
PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y

# ── Step 7: set restoreClusterFromS3Backup=true ────────────────────────────────
echo ""
echo "=== Step 7/7: Set restoreClusterFromS3Backup=true in project_settings.ts ==="
sed -i 's/restoreClusterFromS3Backup\s*:\s*false/restoreClusterFromS3Backup: true/' "$SETTINGS"
echo "  Done."

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster shutdown complete.                                        ║"
echo "║                                                                   ║"
echo "║  Infrastructure preserved. Data backed up to S3.                  ║"
echo "║  To restore: commit project_settings.ts, then run 'make create'   ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
