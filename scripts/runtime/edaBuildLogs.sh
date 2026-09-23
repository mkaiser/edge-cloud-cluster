#!/bin/bash
# Read (or live-tail) the logs of an EDA CI build.
#
# Two sources, because a build log lives in two places at different times:
#   --live   the RUNNING build pod. The only way to watch a log as it is written, and it
#            works ONLY while the job runs — the Kubernetes executor deletes the pod the
#            moment the job ends, taking /builds with it.
#   default  the builds NFS export (nfs-eda-builds-ci), where after_script copies the logs.
#            Survives the pod, so this is what you want post-mortem.
#
# ⚠ THE READER POD MUST RUN ON A LAB NODE. The export is lab-local and only the
# ecc/eda-builder nodes have the NFS CSI driver registered; a cloud node fails with
#   driver name nfs.csi.k8s.io not found in the list of registered CSI drivers
# and the pod sits in ContainerCreating with no other explanation.
set -euo pipefail

NS_RUNNER=gitlab-runner
PROJECT=${PROJECT:-osxcar-sdv-switch}
LIVE=0
JOB=""
FILE=""

usage() {
    cat <<EOF
usage: $(basename "$0") [--live] [--job <id>] [--file <name>] [--list]

  --live          tail inside the running build pod (job must be running)
  --job <id>      job id; default = newest logs-job-* on the export
  --file <name>   log to show; default lists what is there, then shows deploy.log
  --list          just list available job dirs and files

  PROJECT=<name>  project directory on the export (default: $PROJECT)

examples:
  $(basename "$0") --list
  $(basename "$0") --job 75 --file petalinux-config.log
  $(basename "$0") --job 75 --file bitbake-cookerdaemon.log
  $(basename "$0") --live --file petalinux-config.log
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --live) LIVE=1 ;;
        --job) JOB="$2"; shift ;;
        --file) FILE="$2"; shift ;;
        --list) FILE="__list__" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$LIVE" = "1" ]; then
    # project-8 is osxcar-sdv-switch; match the concurrent build pod, not a helper.
    pod=$(kubectl -n "$NS_RUNNER" get pods --no-headers 2>/dev/null \
        | awk '/^runner-.*concurrent/ && $3=="Running" {print $1}' | head -1)
    if [ -z "$pod" ]; then
        echo "No running build pod. The job is not running — omit --live to read the NFS copy." >&2
        exit 1
    fi
    echo "=== live in $pod ===" >&2
    base=/builds/deployments/eda/$PROJECT
    if [ -z "$FILE" ] || [ "$FILE" = "__list__" ]; then
        kubectl -n "$NS_RUNNER" exec "$pod" -c build -- \
            sh -c "ls -la $base/log/ 2>/dev/null; echo; find $base -name 'bitbake-cookerdaemon.log' -o -name '*.log' 2>/dev/null | head -30"
        exit 0
    fi
    # -F, not -f: the tool may rotate or recreate the file mid-build.
    kubectl -n "$NS_RUNNER" exec "$pod" -c build -- \
        sh -c "find $base -name '$FILE' 2>/dev/null | head -1 | xargs -r tail -F"
    exit 0
fi

# ── NFS copy ───────────────────────────────────────────────────────────────────────────
name="eda-build-logs-$$"
sel="$JOB"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $NS_RUNNER
spec:
  nodeSelector:
    ecc/eda-builder: "true"
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: p
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          set -u
          P=/out/$PROJECT
          [ -d "\$P" ] || { echo "no such project dir: \$P"; ls -1 /out 2>/dev/null; exit 1; }
          if [ -n "$sel" ]; then
            D=\$(find "\$P" -maxdepth 2 -type d -name "logs-job-$sel" | head -1)
          else
            D=\$(ls -1dt "\$P"/*/logs-job-* 2>/dev/null | head -1)
          fi
          [ -n "\$D" ] || { echo "no logs-job-* dir found under \$P"; exit 1; }
          echo "=== \$D ==="
          if [ "$FILE" = "__list__" ] || [ -z "$FILE" ]; then
            find "\$D" -type f | sed "s#\$D/##" | sort
          fi
          if [ "$FILE" != "__list__" ]; then
            T="$FILE"; [ -n "\$T" ] || T=deploy.log
            F=\$(find "\$D" -type f -name "\$T" | head -1)
            if [ -n "\$F" ]; then echo; echo "=== \$T ==="; tail -200 "\$F"
            else echo; echo "not found in this job dir: \$T"; fi
          fi
      volumeMounts:
        - name: o
          mountPath: /out
  volumes:
    - name: o
      persistentVolumeClaim:
        claimName: nfs-eda-builds-ci
EOF
trap 'kubectl -n "$NS_RUNNER" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n "$NS_RUNNER" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=150s >/dev/null 2>&1 \
    || kubectl -n "$NS_RUNNER" wait --for=jsonpath='{.status.phase}'=Failed "pod/$name" --timeout=10s >/dev/null 2>&1 || true
kubectl -n "$NS_RUNNER" logs "$name" 2>&1
