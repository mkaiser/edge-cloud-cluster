#!/bin/bash
# Trigger etcd snapshot and Longhorn S3 backups for all volumes.
# Can be run standalone or sourced from shutdownCluster.sh.
set -euo pipefail

_bytes_human() {
    local b=$1
    if [ "$b" -ge 1073741824 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1f GiB\", $b/1073741824}"
    elif [ "$b" -ge 1048576 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1f MiB\", $b/1048576}"
    elif [ "$b" -gt 0 ] 2>/dev/null; then
        echo "${b} B"
    else
        echo "(incremental — no new data)"
    fi
}

# ── etcd snapshot to S3 ───────────────────────────────────────────────────────
echo ""
echo "=== etcd on-demand snapshot → S3 ==="
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
      hostNetwork: true
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
ETCD_OK=false
if kubectl wait --for=condition=complete job/"${JOB_NAME}" -n kube-system --timeout=120s 2>/dev/null; then
    ETCD_OK=true
fi
# Query S3 for etcd snapshot size using credentials from longhorn-s3-credentials secret
ETCD_SNAP_NAME="shutdown-snapshot"
ETCD_SIZE_STR="(see S3 bucket)"
S3_ACCESS=$(kubectl get secret longhorn-s3-credentials -n longhorn-system \
    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
S3_SECRET=$(kubectl get secret longhorn-s3-credentials -n longhorn-system \
    -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)
S3_ENDPOINT="https://nbg1.your-objectstorage.com"
if [ -n "$S3_ACCESS" ] && [ -n "$S3_SECRET" ]; then
    ETCD_S3_LINE=$(AWS_ACCESS_KEY_ID="$S3_ACCESS" AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
        aws s3 ls "s3://edgecloud-etcd/k3s-etcd/" \
        --endpoint-url "$S3_ENDPOINT" 2>/dev/null \
        | grep -i "shutdown-snapshot" | sort | tail -1 || true)
    if [ -n "$ETCD_S3_LINE" ]; then
        ETCD_SNAP_NAME=$(echo "$ETCD_S3_LINE" | awk '{print $NF}')
        ETCD_SIZE_BYTES=$(echo "$ETCD_S3_LINE" | awk '{print $3}')
        ETCD_SIZE_STR=$(_bytes_human "$ETCD_SIZE_BYTES")
    fi
fi

# ── Longhorn S3 backup ────────────────────────────────────────────────────────
echo ""
echo "=== Longhorn — trigger S3 backup for all volumes ==="
LH_DONE=0; LH_TOTAL=0; LH_TOTAL_BYTES=0; LH_STATUS="skipped"
if kubectl get namespace longhorn-system >/dev/null 2>&1; then
    VOLUMES=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$VOLUMES" ]; then
        # Longhorn 1.6+ uses BackupTarget CRD instead of the legacy backup-target Setting.
        BACKUP_TARGET=$(kubectl get backuptarget default -n longhorn-system \
            -o jsonpath='{.spec.backupTargetURL}' 2>/dev/null || true)
        BACKUP_AVAILABLE=$(kubectl get backuptarget default -n longhorn-system \
            -o jsonpath='{.status.available}' 2>/dev/null || true)
        if [ -n "$BACKUP_TARGET" ] && [ "$BACKUP_AVAILABLE" = "true" ]; then
            BACKUP_REASON="${LONGHORN_BACKUP_REASON:-manual}"
            SNAP_SUFFIX="${BACKUP_REASON}-$(date +%s)"
            echo "  Backup target: $BACKUP_TARGET (reason: $BACKUP_REASON)"

            # Step 1: create a Snapshot per volume (v1beta2 API)
            SNAP_NAMES=""
            for VOL in $VOLUMES; do
                SNAP_NAME="${SNAP_SUFFIX}-$(echo "$VOL" | sed 's/pvc-//')"
                SNAP_NAME=$(echo "$SNAP_NAME" | cut -c1-63 | sed 's/-$//')
                kubectl apply -f - <<SEOF 2>/dev/null || true
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: ${SNAP_NAME}
  namespace: longhorn-system
  labels:
    reason: ${BACKUP_REASON}
spec:
  volume: ${VOL}
  createSnapshot: true
  labels:
    reason: ${BACKUP_REASON}
SEOF
                SNAP_NAMES="$SNAP_NAMES $SNAP_NAME"
                echo "  Triggered snapshot for volume: $VOL → $SNAP_NAME"
            done

            # Step 2: wait for all snapshots to become readyToUse (timeout 5min)
            echo "  Waiting for snapshots to be ready..."
            SNAP_DEADLINE=$(($(date +%s) + 300))
            ALL_READY=true
            while [ "$(date +%s)" -lt "$SNAP_DEADLINE" ]; do
                ALL_READY=true
                for S in $SNAP_NAMES; do
                    READY=$(kubectl get snapshot "$S" -n longhorn-system \
                        -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")
                    [ "$READY" != "true" ] && ALL_READY=false && break
                done
                $ALL_READY && break
                sleep 10
            done
            if ! $ALL_READY; then
                echo "  WARNING: some snapshots not ready after 5min — proceeding anyway."
            else
                echo "  All snapshots ready."
            fi

            # Step 3: create a Backup per snapshot
            BACKUP_NAMES=""
            for S in $SNAP_NAMES; do
                BACKUP_NAME="bkp-${S}"
                BACKUP_NAME=$(echo "$BACKUP_NAME" | cut -c1-63 | sed 's/-$//')
                kubectl apply -f - <<BEOF 2>/dev/null || true
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: longhorn-system
  labels:
    reason: ${BACKUP_REASON}
spec:
  snapshotName: ${S}
  labels:
    reason: ${BACKUP_REASON}
BEOF
                BACKUP_NAMES="$BACKUP_NAMES $BACKUP_NAME"
                echo "  Triggered backup: $BACKUP_NAME"
            done

            # Step 4: poll for completion (timeout 10min)
            echo "  Polling for backup completion (timeout 10min)..."
            LH_TOTAL=$(echo $BACKUP_NAMES | wc -w | tr -d ' ')
            LH_DONE=0; LH_FAILED=0
            DEADLINE=$(($(date +%s) + 600))
            while [ "$(date +%s)" -lt "$DEADLINE" ]; do
                LH_DONE=0; LH_FAILED=0
                for B in $BACKUP_NAMES; do
                    STATE=$(kubectl get backup "$B" -n longhorn-system \
                        -o jsonpath='{.status.state}' 2>/dev/null || echo "Missing")
                    case "$STATE" in
                        Completed) LH_DONE=$((LH_DONE+1)) ;;
                        Error)     LH_FAILED=$((LH_FAILED+1)) ;;
                    esac
                done
                echo "  $(date +%H:%M:%S) — completed: ${LH_DONE}/${LH_TOTAL}  failed: ${LH_FAILED}"
                if [ $((LH_DONE + LH_FAILED)) -eq "$LH_TOTAL" ]; then
                    break
                fi
                sleep 10
            done
            if [ "${LH_FAILED:-0}" -gt 0 ]; then
                LH_STATUS="partial (${LH_FAILED} failed)"
                echo "  WARNING: ${LH_FAILED} backup(s) failed:"
                for B in $BACKUP_NAMES; do
                    STATE=$(kubectl get backup "$B" -n longhorn-system \
                        -o jsonpath='{.status.state}' 2>/dev/null || echo "Missing")
                    [ "$STATE" = "Error" ] && echo "    - $B: $(kubectl get backup "$B" -n longhorn-system \
                        -o jsonpath='{.status.error}' 2>/dev/null)"
                done
            elif [ "$LH_DONE" -eq "$LH_TOTAL" ]; then
                LH_STATUS="OK"
            else
                LH_STATUS="timed out"
                echo "  WARNING: timed out — ${LH_DONE}/${LH_TOTAL} completed."
                echo "  Check: kubectl get backups.longhorn.io -n longhorn-system"
            fi

            # Collect total uploaded bytes
            for B in $BACKUP_NAMES; do
                BYTES=$(kubectl get backup "$B" -n longhorn-system \
                    -o jsonpath='{.status.newlyUploadDataSize}' 2>/dev/null || echo "0")
                LH_TOTAL_BYTES=$((LH_TOTAL_BYTES + ${BYTES:-0}))
            done
        else
            echo "  No S3 backup target configured in Longhorn — skipping."
        fi
    else
        echo "  No Longhorn volumes found — skipping."
    fi
else
    echo "  Longhorn not installed — skipping."
fi

# ── Combined summary ───────────────────────────────────────────────────────────
LH_HUMAN=$(_bytes_human "$LH_TOTAL_BYTES")

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Backup Summary                                             │"
echo "├─────────────────────────────────────────────────────────────┤"
if $ETCD_OK; then
    printf "│  etcd     : OK\n"
    printf "│  snapshot : %s\n" "$ETCD_SNAP_NAME"
    printf "│  size     : %s\n" "$ETCD_SIZE_STR"
else
    printf "│  etcd     : FAILED\n"
    printf "│  check    : kubectl logs job/%s -n kube-system\n" "$JOB_NAME"
fi
echo "├─────────────────────────────────────────────────────────────┤"
if [ "$LH_STATUS" = "skipped" ]; then
    printf "│  Longhorn : skipped (not installed or no S3 target)\n"
else
    printf "│  Longhorn : %s\n" "$LH_STATUS"
    printf "│  PVCs     : %s/%s\n" "$LH_DONE" "$LH_TOTAL"
    printf "│  uploaded : %s\n" "$LH_HUMAN"
fi
echo "└─────────────────────────────────────────────────────────────┘"
