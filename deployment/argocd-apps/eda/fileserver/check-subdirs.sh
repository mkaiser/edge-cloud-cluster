#!/bin/bash
# Assert the EDA archive-path derivations agree across the places that derive them.
#
# WHY THIS EXISTS: the same <name>/<version> subdirectory string is derived independently
# in two places, and if they disagree the failure is SILENT — a build reports "no .tar.gz
# found", which reads like missing media rather than a missing mkdir. The two:
#
#   1. each eda app's .gitlab-ci.yml   $MEDIA_DIR (where the build READS vendor media)
#   2. eda/fileserver/provision-job.yaml  SUBDIRS (which directories are CREATED)
#
# ⚠ MEDIA ONLY — image archives are deliberately NOT covered. Container images are not
# archived: the registry blob store is the only copy, and a missing image is repaired by
# re-running the app's pipeline, which rebuilds from the media this script guards. That
# media is the irreplaceable half — for HyperLynx there is no upstream to re-fetch it from.
#
# A CHECK, not a generator, on purpose: the first path segment is DELIBERATELY asymmetric
# (`xilinx` is a vendor, `hyperlynx` is the tool) and the comments on both sides explicitly
# forbid "correcting" it.
#
# Also asserts every NFS `share:` line — the four EDA PVs plus the two homes consumers —
# equals /mnt/<dataset> from project_settings.ts. Those lines deliberately carry NO
# project-settings anchor (the substitution regex would eat the /mnt prefix), so they are
# hand-maintained — which is exactly why they need checking.
#
#   ./check-subdirs.sh    exit 1 on any mismatch, reporting file:line
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os, re, sys, glob

root = sys.argv[1]
fail = []

def rel(p):
    return os.path.relpath(p, root)

def find_line(path, needle):
    for i, l in enumerate(open(path), 1):
        if needle in l:
            return i
    return 0

# ── 2. each app's CI: $MEDIA_DIR under /artifacts ────────────────────────────────
# MEDIA_DIR may be expressed in terms of MODULE_DIR (hyperlynx); resolve one level.
ci_subdirs = {}
for ci in sorted(glob.glob(os.path.join(root, "deployment/argocd-apps/eda/*/.gitlab-ci.yml"))):
    txt = open(ci).read()
    vals = {}
    # MODULE_DIR exists only where MEDIA_DIR is expressed relative to it (hyperlynx).
    for key in ("MEDIA_DIR", "MODULE_DIR"):
        mm = re.search(rf'^\s+{key}:\s*(\S+)\s*$', txt, re.M)
        if mm:
            vals[key] = mm.group(1)
    tag = re.search(r'^\s+IMAGE_TAG:\s*"([^"]+)"', txt, re.M)
    raw = vals.get("MEDIA_DIR")
    if not raw:
        continue
    # resolve $MODULE_DIR / $MEDIA_DIR / $IMAGE_TAG one level
    for k, v in vals.items():
        raw = raw.replace(f"${k}", v)
    if tag:
        raw = raw.replace("$IMAGE_TAG", tag.group(1))
    if not raw.startswith("/artifacts/"):
        continue
    ci_subdirs[rel(ci)] = (raw[len("/artifacts/"):].rstrip("/"), find_line(ci, raw.split("/")[-1]))

# ── 3. provision-job.yaml SUBDIRS ────────────────────────────────────────────────
pj = os.path.join(root, "deployment/argocd-apps/eda/fileserver/provision-job.yaml")
pt = open(pj).read()
mm = re.search(r'SUBDIRS = \(\s*(.*?)\)', pt, re.S)
if not mm:
    print(f"ERROR: could not parse SUBDIRS in {rel(pj)}", file=sys.stderr)
    sys.exit(2)
subdirs = set(re.findall(r'"([^"]+)"', mm.group(1)))
pl = find_line(pj, "SUBDIRS = (")

# ── assertions ───────────────────────────────────────────────────────────────────
# every directory a build READS media from must actually be provisioned
for f, (sub, ln) in sorted(ci_subdirs.items()):
    if sub not in subdirs:
        fail.append(f"{f}:{ln}: reads installer media from /artifacts/{sub}, but "
                    f"{rel(pj)}:{pl} SUBDIRS does not create '{sub}' — the build would "
                    f"report \"no .tar.gz found\", which reads like missing media")

# a provisioned subdir no CI reads is harmless but worth surfacing
ci_vals = {v for v, _ in ci_subdirs.values()}
for sub in sorted(subdirs):
    if "/" in sub and sub not in ci_vals and not any(v.startswith(sub + "/") for v in ci_vals):
        print(f"note: SUBDIRS creates '{sub}' but no CI reads it "
              f"(fine if that app is disabled)")

# ── 4. PV share: lines must equal /mnt/<dataset> from project_settings.ts ─────────
ps = open(os.path.join(root, "project_settings.ts")).read()


def ts_block(name):
    r"""Body of the `name: {` object in project_settings.ts, at ANY nesting depth.

    Brace-depth counted rather than terminated on a fixed indent: an indent-pinned close
    (the old `^    \},`) silently mis-slices the moment a block moves one level deeper, and
    the slice then swallows its siblings instead of erroring. Depth also stops at the
    block's OWN closing brace, so a key missing from it can never be answered from the next
    block. `//` comments are skipped so a commented brace cannot unbalance the count.
    """
    m = re.search(rf'^[ \t]*{re.escape(name)}:[ \t]*\{{', ps, re.M)
    if not m:
        print(f"ERROR: no `{name}:` block in project_settings.ts", file=sys.stderr)
        sys.exit(2)
    depth, start, i, n = 1, m.end(), m.end(), len(ps)
    while i < n:
        if ps[i] == "/" and ps[i:i + 2] == "//":
            nl = ps.find("\n", i)
            i = n if nl == -1 else nl
            continue
        if ps[i] == "{":
            depth += 1
        elif ps[i] == "}":
            depth -= 1
            if depth == 0:
                return ps[start:i]
        i += 1
    print(f"ERROR: unterminated `{name}:` block in project_settings.ts", file=sys.stderr)
    sys.exit(2)


# ⚠ Scope every lookup to its own block. An unscoped search for a key as generic as
# `artifacts:`, `registry:` or `dataset:` would happily match another block's and silently
# compare against the wrong dataset.
_eda_txt = ts_block("eda")
# The OCI blob store is NOT in the eda: block — it holds image-archives/{remote-desktop,
# ollama,vllm} as well as the module images, so it is not EDA and has its own block.
_img_txt = ts_block("imageRegistry")

BLOCK_OF = {"images": (_img_txt, "storage.fileserver.datasets.imageRegistry.dataset", "dataset")}


def ds(key):
    txt, _, field = BLOCK_OF.get(key, (_eda_txt, f"storage.fileserver.datasets.eda.{key}", key))
    mm = re.search(rf'^\s+{field}:\s*"([^"]+)"', txt, re.M)
    return mm.group(1) if mm else None


def ds_label(key):
    return BLOCK_OF.get(key, (None, f"storage.fileserver.datasets.eda.{key}", None))[1]

# `homes` has its own top-level block, same reasoning: the dataset name lives with the app
# that mounts it. Its two consumers' share: lines carry no anchor either, for the same
# /mnt-prefix reason, so they are checked here too.
_hm = re.search(r'^\s+dataset:\s*"([^"]+)"', ts_block("homes"), re.M)
HOMES_DS = _hm.group(1) if _hm else None

# `shared` is a parent + two exported children, same shape as `eda`. Its two `share:` lines
# DO carry anchors, but they are checked here anyway: the anchor keeps the value in step
# with project_settings, while this asserts the /mnt prefix and the parent/child split that
# no anchor can express.
_shared_txt = ts_block("shared")
def _sh(key):
    mm = re.search(rf'^\s+{key}:\s*"([^"]+)"', _shared_txt, re.M)
    return mm.group(1) if mm else None
SHARED_PARENT_DS = _sh("parent")
SHARED_DS        = _sh("dataset")
SHARED_TMP_DS    = _sh("tmpDataset")
# ⚠ The children MUST live under the parent. If they ever stop doing so, the "parent is not
# exported" rule silently stops protecting anything.
for _k, _v in (("dataset", SHARED_DS), ("tmpDataset", SHARED_TMP_DS)):
    if not _v or not SHARED_PARENT_DS or not _v.startswith(SHARED_PARENT_DS + "/"):
        fail.append(f"project_settings storage.fileserver.datasets.shared.{_k} ({_v}) is not a child of "
                    f"storage.fileserver.datasets.shared.parent ({SHARED_PARENT_DS})")

# ⚠ There is deliberately no remote-desktop/artifacts-pv.yaml: the broker would mount
# /artifacts only to read image archives, and there are none. Do not add it without a
# reason — it would also give the broker write access to the vendor media tree.
pv_expect = {
    "deployment/argocd-apps/gitlab-runner-eda/nfs-installers-pv.yaml": ("installers", ""),
    "deployment/argocd-apps/remote-desktop/nfs-eda-modulefiles-pv.yaml":               ("moduleFiles", ""),
    # ⚠ A SECOND CLAIM ON THE MODULE REGISTRY. Mounting this export is root-execution
    # authority (see remote-desktop/README.md) — it is listed here so the share: path is
    # checked like any other, NOT as an invitation to add a third.
    "deployment/argocd-apps/remote-desktop-bender/nfs-eda-modulefiles-bender-pv.yaml": ("moduleFiles", ""),
    "deployment/argocd-apps/image-registry/nfs-images-pv.yaml":                    ("images", ""),
    "deployment/argocd-apps/eda/fileserver/nfs-eda-builds-pv.yaml":                ("builds", ""),
}
# The homes consumer, hand-maintained for the same reason. There is no NFS StorageClass —
# csi-driver-nfs is deployed for its NODE driver only; every NFS volume here is a static PV.
homes_expect = {
    "deployment/argocd-apps/remote-desktop/nfs-homes-pv.yaml": None,
    # Every workstation gets its OWN claim over the same export — a PV binds 1:1 to a PVC.
    # eda-pcb-agent was missing here until 2026-09-14, so the repo's second homes PV was
    # unchecked by the naming contract below; that is how a stem/name mismatch would have
    # become precedent.
    "deployment/argocd-apps/eda-pcb-agent/nfs-homes-pv.yaml": None,
    "deployment/argocd-apps/remote-desktop-bender/nfs-homes-bender-pv.yaml": None,
    "deployment/argocd-apps/hermes/nfs-homes-hermes-pv.yaml": None,
}
for f, (key, suffix) in sorted(pv_expect.items()):
    path = os.path.join(root, f)
    if not os.path.exists(path):
        fail.append(f"{f}: expected PV file is missing")
        continue
    mm = re.search(r'^\s+share:\s*(\S+?)\s*(?:#.*)?$', open(path).read(), re.M)
    if not mm:
        fail.append(f"{f}: no `share:` line found")
        continue
    got = mm.group(1)
    dataset = ds(key)
    if not dataset:
        fail.append(f"project_settings.ts: {ds_label(key)} not found")
        continue
    want = f"/mnt/{dataset}{suffix}"
    if got != want:
        fail.append(f"{f}:{find_line(path,'share:')}: share is {got}, expected {want} "
                    f"(from project_settings {ds_label(key)})")

for f in sorted(homes_expect):
    path = os.path.join(root, f)
    if not os.path.exists(path):
        fail.append(f"{f}: expected file is missing")
        continue
    mm = re.search(r'^\s+share:\s*(\S+?)\s*(?:#.*)?$', open(path).read(), re.M)
    if not mm:
        fail.append(f"{f}: no `share:` line found")
        continue
    want = f"/mnt/{HOMES_DS}"
    if mm.group(1) != want:
        fail.append(f"{f}:{find_line(path,'share:')}: share is {mm.group(1)}, expected "
                    f"{want} (from project_settings storage.fileserver.datasets.homes.dataset)")

# ── 5. the two shared children's share: lines ────────────────────────────────────
# One entry per consumer: each defines BOTH children (data then tmp) in one file, because
# /shared/tmp is a separate dataset nested inside /shared and mounting only the parent
# leaves tmp empty.
_shared_pvs = [
    "deployment/argocd-apps/remote-desktop/nfs-shared-pv.yaml",
    "deployment/argocd-apps/remote-desktop-bender/nfs-shared-bender-pv.yaml",
]
for _rel in _shared_pvs:
    _shared_pv = os.path.join(root, _rel)
    if not os.path.exists(_shared_pv):
        fail.append(f"{_rel}: missing")
        continue
    _txt = open(_shared_pv).read()
    _got = re.findall(r'^\s+share:\s*(\S+?)\s*(?:#.*)?$', _txt, re.M)
    _want = [f"/mnt/{SHARED_DS}", f"/mnt/{SHARED_TMP_DS}"]
    if _got != _want:
        fail.append(f"{os.path.basename(_rel)}: share: lines are {_got}, expected {_want} "
                    f"(from project_settings storage.fileserver.datasets.shared.{dataset,tmpDataset})")

# ── 6. NAMING CONTRACT: PV name == PVC name == filename stem ─────────────────────
# This is what keeps the four naming layers (dataset, export label, PV/PVC, filename) from
# drifting apart again. Each static NFS PV file is named for the volume it defines, and the
# PV and its claim share that name — so a file's name predicts every object inside it.
_nfs_pv_files = sorted(set(list(pv_expect) + list(homes_expect) + _shared_pvs))
for f in _nfs_pv_files:
    path = os.path.join(root, f)
    if not os.path.exists(path):
        continue
    txt = open(path).read()
    stem = os.path.basename(f)[:-len("-pv.yaml")]
    pv_names  = re.findall(r'^kind: PersistentVolume\s*\nmetadata:\n\s+name:\s*(\S+)', txt, re.M)
    pvc_names = re.findall(r'^kind: PersistentVolumeClaim\s*\nmetadata:\n\s+name:\s*(\S+)', txt, re.M)
    if not pv_names:
        fail.append(f"{f}: no PersistentVolume name found")
        continue
    if sorted(pv_names) != sorted(pvc_names):
        fail.append(f"{f}: PV names {pv_names} != PVC names {pvc_names} — every static NFS "
                    f"PV must be claimed by a PVC of the SAME name")
    for n in pv_names:
        if not (n == stem or n.startswith(stem.rsplit("-", 1)[0])):
            fail.append(f"{f}: volume {n!r} does not match the filename stem {stem!r} "
                        f"(convention: <name>-pv.yaml defines volume <name>)")

if fail:
    print(f"\nEDA subdir/share contract FAILED — {len(fail)} mismatch(es):", file=sys.stderr)
    for f in fail:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print(f"ok: {len(ci_subdirs)} CI media path(s) and {len(subdirs)} provisioned subdir(s) "
      f"agree; all {len(pv_expect) + len(homes_expect) + 2 * len(_shared_pvs)} share: lines match "
      f"project_settings; {len(_nfs_pv_files)} NFS PV file(s) match the naming contract")
PY
