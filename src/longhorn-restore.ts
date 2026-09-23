/**
 * Project: edgecloudinfra
 * File: longhorn-restore.ts
 * Purpose: Longhorn restore helper utilities.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as fs from "fs";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";

const longhornBucket = project_settings.storage.objectStorage.buckets.find(
    (b) => b.key === "longhornBackup",
)!;
const BACKUP_BUCKET = longhornBucket.name;
const BACKUP_REGION = longhornBucket.location;
const LONGHORN_PORT = 8091;

// Namespaces whose volumes are NOT restored at cloud-cluster creation: only apps
// tagged placement.ecc/tier: mesh — their data lives on mesh-node disks
// (longhorn-<scope>), so there's nothing to restore onto the cloud plane.
//
// IMPORTANT: `flex`-tier apps are deliberately NOT skipped here. They are still
// cloud-resident on longhorn-cloud (their SeaweedFS/CNPG mobility migration is
// deferred), so their data MUST be restored to cloud. Once a `flex` app actually
// moves off cloud, its data lives in SeaweedFS/CNPG and it has no cloud Longhorn
// backup to restore anyway, so this stays correct. (The windows VM is `flex` now —
// KVM-anywhere — so it is restored to cloud while pinned to longhorn-cloud.)
//
// Scanned from git manifests because the apps aren't synced yet when restore runs.
function deferredNamespacesFromManifests(): string[] {
    // Mesh-tier apps now live under argocd-apps/app-of-apps/ (managed by the apps ArgoCD);
    // infra Applications stay under argocd-infra/app-of-apps/. Scan both so
    // any mesh-tier manifest in either tree is picked up.
    const dirs = [
        path.join(__dirname, "..", "deployment", "argocd-infra", "app-of-apps"),
        path.join(__dirname, "..", "deployment", "argocd-apps", "app-of-apps"),
    ];
    const out = new Set<string>();
    for (const dir of dirs) {
        let files: string[];
        try {
            files = fs.readdirSync(dir).filter((f) => f.endsWith(".yaml"));
        } catch {
            continue;
        }
        for (const f of files) {
            const txt = fs.readFileSync(path.join(dir, f), "utf8");
            const tierM = txt.match(/placement\.ecc\/tier:\s*["']?(\w+)["']?/);
            // Only mesh-tier apps are off-cloud; flex/cloud volumes restore to cloud.
            if (!tierM || tierM[1] !== "mesh") continue;
            // destination.namespace = the namespace value that isn't an ArgoCD ns
            const nsAll = [...txt.matchAll(/^\s*namespace:\s*["']?([\w-]+)["']?\s*$/gm)].map(
                (m) => m[1],
            );
            const ns = nsAll.find((n) => n !== "argocd-infra" && n !== "argocd-apps");
            if (ns) out.add(ns);
        }
    }
    return [...out];
}
const DEFERRED_NAMESPACES = deferredNamespacesFromManifests();

// Runs during `pulumi up` when general.targetState is "restore".
// Port-forwards the Longhorn API, waits for the backup target, then restores
// every volume that has a backup in S3 but no healthy replicas on the new cluster.
export interface LonghornRestoreArgs {
    kubeconfigRaw: pulumi.Output<string>;
}

export class LonghornRestoreComponent extends pulumi.ComponentResource {
    constructor(name: string, args: LonghornRestoreArgs, opts?: pulumi.ComponentResourceOptions) {
        super("edgecloudinfra:index:LonghornRestore", name, {}, opts);

        new command.local.Command(
            "longhorn-restore-volumes",
            {
                create: [
                    `LONGHORN_PORT=${LONGHORN_PORT}`,
                    `BACKUP_BUCKET="${BACKUP_BUCKET}"`,
                    `BACKUP_REGION="${BACKUP_REGION}"`,
                    ``,
                    `TMPKC=$(mktemp)`,
                    `cleanup() {`,
                    `    if [ -n "\${PF_PID:-}" ]; then`,
                    `        kill "\$PF_PID" 2>/dev/null || true`,
                    `        wait "\$PF_PID" 2>/dev/null || true`,
                    `    fi`,
                    `    rm -f "$TMPKC"`,
                    `}`,
                    `trap cleanup EXIT`,
                    `printf '%s\\n' "$KUBECONFIG_CONTENT" > "$TMPKC"`,
                    `export KUBECONFIG="$TMPKC"`,
                    ``,
                    `echo "=== Longhorn restore from S3 ==="`,
                    `# Redirect ALL three fds with POSIX syntax (this runs under /bin/sh,`,
                    `# NOT bash): the bashism "&>file" parses in dash as "background &"`,
                    `# + a separate ">file", leaving the port-forward attached to pulumi's`,
                    `# stdout/stderr pipe — so pulumi never sees EOF and the Command hangs`,
                    `# forever even after this script exits. ">file 2>&1 </dev/null &"`,
                    `# detaches every fd so the backgrounded PF holds none of pulumi's pipes.`,
                    `kubectl port-forward svc/longhorn-frontend -n longhorn-system \\`,
                    `    "\${LONGHORN_PORT}:80" --address=127.0.0.1 \\`,
                    `    >/tmp/longhorn-restore-pf.log 2>&1 </dev/null &`,
                    `PF_PID=$!`,
                    ``,
                    `echo "Waiting for Longhorn API (up to 5 min)..."`,
                    `for i in $(seq 1 60); do`,
                    `    if curl -sf "http://localhost:\${LONGHORN_PORT}/v1/volumes" >/dev/null 2>&1; then`,
                    `        echo "  Longhorn API ready."`,
                    `        break`,
                    `    fi`,
                    `    [ "$i" = "60" ] && { echo "ERROR: Longhorn API not ready"; exit 1; }`,
                    `    sleep 5`,
                    `done`,
                    ``,
                    `echo "Waiting for backup target (up to 5 min)..."`,
                    `for i in $(seq 1 60); do`,
                    `    AVAIL=$(curl -sf "http://localhost:\${LONGHORN_PORT}/v1/backuptargets/default" \\`,
                    `        | python3 -c "import sys,json; print(json.load(sys.stdin).get('available',False))" 2>/dev/null || echo "False")`,
                    `    if [ "$AVAIL" = "True" ]; then`,
                    `        echo "  Backup target available."`,
                    `        break`,
                    `    fi`,
                    `    [ "$i" = "60" ] && { echo "ERROR: Backup target not available"; exit 1; }`,
                    `    sleep 5`,
                    `done`,
                    ``,
                    `python3 - "\${LONGHORN_PORT}" "\${BACKUP_BUCKET}" "\${BACKUP_REGION}" << 'PYEOF'`,
                    `import sys, os, urllib.request, json, time`,
                    ``,
                    `port, bucket, region = sys.argv[1], sys.argv[2], sys.argv[3]`,
                    `base = f"http://localhost:{port}/v1"`,
                    `# Namespaces tagged tier mesh — their volumes are NOT restored to cloud.`,
                    `deferred = set(json.loads(os.environ.get("DEFERRED_NAMESPACES", "[]")))`,
                    `print(f"Deferred (non-cloud) namespaces: {sorted(deferred) or 'none'}")`,
                    ``,
                    `def ns_of(obj):`,
                    `    # Longhorn stores the source PVC namespace as a JSON 'KubernetesStatus' label.`,
                    `    labels = obj.get("labels") or {}`,
                    `    raw = labels.get("KubernetesStatus")`,
                    `    if not raw:`,
                    `        return ""`,
                    `    try:`,
                    `        return (json.loads(raw) or {}).get("namespace", "") or ""`,
                    `    except Exception:`,
                    `        return ""`,
                    ``,
                    `def api_get(path):`,
                    `    with urllib.request.urlopen(urllib.request.Request(f"{base}{path}"), timeout=30) as r:`,
                    `        return json.load(r)`,
                    ``,
                    `def api_post(path, body):`,
                    `    data = json.dumps(body).encode()`,
                    `    req = urllib.request.Request(f"{base}{path}", data=data,`,
                    `                                  headers={"Content-Type": "application/json"})`,
                    `    with urllib.request.urlopen(req, timeout=60) as r:`,
                    `        return json.load(r)`,
                    ``,
                    `def api_delete(path):`,
                    `    req = urllib.request.Request(f"{base}{path}", method="DELETE")`,
                    `    with urllib.request.urlopen(req, timeout=30) as r:`,
                    `        return r.read()`,
                    ``,
                    `existing = {v["name"]: v for v in api_get("/volumes?limit=200")["data"]}`,
                    `bvols    = api_get("/backupvolumes?limit=200")["data"]`,
                    `print(f"Existing Longhorn volumes: {len(existing)}")`,
                    `print(f"Backup volumes in S3:      {len(bvols)}")`,
                    ``,
                    `if not bvols:`,
                    `    print("No backups found in S3 — bucket is empty. Skipping restore.")`,
                    `    sys.exit(0)`,
                    ``,
                    `restored, skipped, failed = [], [], []`,
                    ``,
                    `for bv in bvols:`,
                    `    vol_name = bv["volumeName"]`,
                    `    bv_id    = bv["id"]`,
                    `    last_bk  = bv.get("lastBackupName", "")`,
                    `    vol_size = str(bv.get("size", "0"))`,
                    ``,
                    `    if not last_bk:`,
                    `        print(f"  SKIP  {vol_name}: no backups in S3")`,
                    `        skipped.append(vol_name)`,
                    `        continue`,
                    ``,
                    `    ns = ns_of(bv)`,
                    `    if ns and ns in deferred:`,
                    `        print(f"  SKIP  {vol_name}: namespace '{ns}' is non-cloud tier (not restored here)")`,
                    `        skipped.append(vol_name)`,
                    `        continue`,
                    ``,
                    `    # Get canonical backup URL from Longhorn API (query-param format)`,
                    `    try:`,
                    `        bk_info    = api_post(f"/backupvolumes/{bv_id}?action=backupGet", {"name": last_bk})`,
                    `        backup_url = bk_info["url"]`,
                    `    except Exception as e:`,
                    `        print(f"  FAIL  {vol_name}: could not get backup URL: {e}")`,
                    `        failed.append(vol_name)`,
                    `        continue`,
                    ``,
                    `    if not ns:  # fall back to the backup's own KubernetesStatus label`,
                    `        ns = ns_of(bk_info)`,
                    `        if ns and ns in deferred:`,
                    `            print(f"  SKIP  {vol_name}: namespace '{ns}' is non-cloud tier (not restored here)")`,
                    `            skipped.append(vol_name)`,
                    `            continue`,
                    ``,
                    `    if vol_name in existing:`,
                    `        v = existing[vol_name]`,
                    `        if v.get("state") in ("restoring", "attaching"):`,
                    `            print(f"  SKIP  {vol_name}: already restoring/attaching")`,
                    `            skipped.append(vol_name)`,
                    `            continue`,
                    `        running = [r for r in v.get("replicas", []) if r.get("running") and r.get("mode") == "RW"]`,
                    `        if running:`,
                    `            print(f"  SKIP  {vol_name}: {len(running)} healthy replica(s)")`,
                    `            skipped.append(vol_name)`,
                    `            continue`,
                    `        print(f"  DEL   {vol_name}: no healthy replicas")`,
                    `        try:`,
                    `            if v.get("state") == "attached":`,
                    `                api_post(f"/volumes/{vol_name}?action=detach", {"hostId": ""})`,
                    `                time.sleep(5)`,
                    `            api_delete(f"/volumes/{vol_name}")`,
                    `            time.sleep(2)`,
                    `        except Exception as e:`,
                    `            print(f"    WARNING: delete failed: {e}")`,
                    ``,
                    `    print(f"  RESTORE {vol_name}")`,
                    `    try:`,
                    `        api_post("/volumes", {`,
                    `            "name":             vol_name,`,
                    `            "fromBackup":       backup_url,`,
                    `            "numberOfReplicas": 2,`,
                    `            "size":             vol_size,`,
                    `        })`,
                    `        restored.append(vol_name)`,
                    `    except urllib.error.HTTPError as e:`,
                    `        msg = e.read().decode()`,
                    `        print(f"    FAIL {e.code}: {msg[:200]}")`,
                    `        failed.append(vol_name)`,
                    ``,
                    `print(f"\\nRestored: {len(restored)}  Skipped: {len(skipped)}  Failed: {len(failed)}")`,
                    `if failed:`,
                    `    print(f"Failed volumes: {failed}")`,
                    `    sys.exit(1)`,
                    ``,
                    `if not restored:`,
                    `    print("Nothing to restore — all volumes already healthy.")`,
                    `    sys.exit(0)`,
                    ``,
                    `print("\\nWaiting for volumes to finish restoring (up to 30 min)...")`,
                    `deadline = time.time() + 1800`,
                    `pending  = set(restored)`,
                    `while pending and time.time() < deadline:`,
                    `    still = set()`,
                    `    for v in api_get("/volumes?limit=200")["data"]:`,
                    `        if v["name"] not in pending:`,
                    `            continue`,
                    `        restoring = any(`,
                    `            rs.get("isRestoring") or`,
                    `            (rs.get("progress", 100) < 100 and rs.get("state") not in ("", "complete"))`,
                    `            for rs in v.get("restoreStatus", [])`,
                    `        )`,
                    `        if restoring or v.get("state") == "restoring":`,
                    `            still.add(v["name"])`,
                    `        else:`,
                    `            print(f"  DONE  {v['name']}  state={v['state']}  robustness={v.get('robustness','?')}")`,
                    `    if still:`,
                    `        print(f"  ... {len(still)} volume(s) still restoring")`,
                    `        time.sleep(15)`,
                    `    pending = still`,
                    ``,
                    `if pending:`,
                    `    print(f"WARNING: {len(pending)} volume(s) did not finish in 30 min: {pending}")`,
                    `else:`,
                    `    print("\\nAll volumes restored successfully.")`,
                    `PYEOF`,
                ].join("\n"),
                delete: "true",
                environment: {
                    KUBECONFIG_CONTENT: args.kubeconfigRaw,
                    DEFERRED_NAMESPACES: JSON.stringify(DEFERRED_NAMESPACES),
                },
            },
            { parent: this, customTimeouts: { create: "40m" } },
        );

        this.registerOutputs({});
    }
}
