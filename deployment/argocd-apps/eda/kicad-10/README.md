# KiCad 10 — EDA module

`module load kicad/10.0.6` on the remote-desktop, giving humans a GUI to open boards with.

## Why this exists

The eda-pcb-agent generates KiCad projects into its NFS home. The remote-desktop that humans
log into had **no KiCad at all** — verified 2026-09-20, `command -v kicad kicad-cli` returned
nothing — so those boards could be listed but not opened. The files themselves were never the
problem: both pods mount the same TrueNAS export
(`fs-1.ad.base.internal:/mnt/datapool/homes`), so nothing needs copying or syncing. The gap
was exactly one thing, a GUI, and that is what this module supplies.

`doc/kicad-as-eda-module.md` recommends AGAINST routing the agent through a module, and that
still holds: the agent has KiCad in its sidecar, reaches it through the `kicad` bridge, and
has neither podman nor a broker to run a module with. This module changes nothing on the
agent's path. It is for people at a desktop.

## Why a module and not KiCad baked into the desktop image

Baking it in would be simpler, and neither reason below is about image size.

1. **Two majors will have to coexist.** This project has hit the file-format incompatibility
   in both directions — 9.0.9 cannot read libraries authored by a newer KiCad, and a
   schematic written by 10 cannot be opened by 9. As soon as one board is frozen on 9.x while
   new work moves to 10, `module load kicad/9.0.9` beside `kicad/10.0.6` is precisely the
   problem modules solve. A baked-in single version forecloses it. Adding that second major
   means copying this directory to `kicad-9` and adding one element to the ApplicationSet.
2. **It keeps the desktop image out of the EDA release cadence.** The desktop image is on the
   critical path for every interactive user; a KiCad bump should not force a rebuild of it.

## How it differs from the other modules here

KiCad is FOSS, and that removes two things every sibling app has:

- **No license server, so no `set_from_secret` block** in `module.yaml`. Copy
  `petalinux-2024-1` if you are deriving a new app from this one — it is the unlicensed
  analogue. Do not copy `hyperlynx`.
- **No installer media.** There is nothing staged under `/artifacts`, so the CI job has no
  media-staging step, no `-v /installer` bind mount, and a 1h timeout instead of 4h. The
  whole build is an apt install over the KiCad PPA.

## Three things that will bite

**The library packages are not optional.** `kicad-symbols`, `kicad-footprints` and
`kicad-templates` must be installed alongside `kicad`. Without them a schematic opens with
every symbol unresolved — a page of question marks that reads as a *corrupt file*, not as a
missing package. The Dockerfile asserts that real `.kicad_sym` and `.pretty` libraries landed,
so this fails the build rather than a user's first open.

**The base release and the PPA are coupled.** A PPA publishes per Ubuntu series, so the
`FROM` tag must name a series the KiCad PPA actually builds for. `add-apt-repository` will
happily add a suite that 404s, and the failure surfaces much later as *"kicad has no
installation candidate"* — which reads as a package problem, not a base-image one. Verified
2026-09-20 against `ppa.launchpadcontent.net/kicad/kicad-10.0-releases/ubuntu/dists/`:
`resolute` (26.04) is published and carries `10.0.6~ubuntu26.04.1` for every package
installed. Check that same path before moving the base tag.

**The GUI needs the CLASSIC SVG loader, and the CLI will not tell you.** `librsvg2-common`
must be installed. Without it the only SVG decoder present is GTK's newer **glycin**, which
sandboxes every decode by spawning `bwrap --unshare-all` — and that needs unprivileged user
namespaces the module container cannot have inside the gVisor-sandboxed desktop pod. The
loader process dies, and GTK converts that into a *fatal assertion* the moment it draws its
first SVG icon:

```
Gtk:ERROR ensure_surface_for_gicon: assertion failed (error == NULL):
  Failed to load .../Adwaita/scalable/status/image-missing.svg:
  Loader process exited early with status '1'  Command: "bwrap" "--unshare-all" ...
Bail out!
```

Measured 2026-09-20 opening a project: the GUI started, then died. `kicad-cli` is completely
unaffected — it renders SVGs happily — so no version or CLI check can catch this. It takes a
real GUI launch, which is why it survived the first round of testing. The Dockerfile now
asserts the loader is both present and registered in `loaders.cache`, and the entrypoint
points `GDK_PIXBUF_MODULE_FILE` at that cache.

## Where KiCad comes from, and which version you get

**Upstream, via apt.** The KiCad project's own Launchpad PPA —
`ppa:kicad/kicad-10.0-releases` — not a manually downloaded `.deb`, and not Ubuntu's archive
package (which lags the release badly). Apt gets dependency resolution and, importantly, the
matching `kicad-symbols` / `kicad-footprints` / `kicad-packages3d` from the *same* source, at
the same version. Mixing library packages across sources is how you get subtly wrong symbols.

**You do NOT automatically get the newest version. That is deliberate.** Two independent
pins hold it:

1. **The PPA channel is `kicad-10.0-releases`**, never the rolling `kicad-releases`. It only
   ever serves 10.0.x — a new major cannot arrive through it.
2. **The Dockerfile asserts `kicad-cli version` starts with `10.0.6`** and fails the build
   otherwise.

So when upstream publishes 10.0.7 into that PPA, the next build **fails loudly** rather than
silently producing a different image. That is the point: `IMAGE_TAG` is the sole cache key for
the recover-or-rebuild gate, so an unpinned source lets two builds of the same tag be
different images, and the gate would then skip a rebuild over an image that is no longer what
its tag claims.

### Upgrading a patch release (10.0.6 → 10.0.7)

A deliberate edit in three places, plus the ConfigMap copies:

| file | what changes |
| ---- | ------------ |
| `module.yaml` | `version: "10.0.6"` |
| `.gitlab-ci.yml` | `IMAGE_TAG` and `MODULE_VERSION` |
| `Dockerfile` | the `10.0.6*)` case in the version assertion |

Then re-sync `build-files-configmap.yaml` — it embeds all three and the trigger mirrors the
**ConfigMap**, not the sibling files. Precommit enforces that they match, so a half-done
upgrade is caught before it is committed.

⚠ Bumping the version is a CONTENT change, so the tag bump is correct here. Do not confuse
this with a cluster recreate, where bumping any `IMAGE_TAG` is wrong — it invalidates the
archive that exists precisely to survive the recreate.

### A new major (11.x)

Do **not** upgrade this app in place. Copy the directory to `kicad-11`, point it at
`ppa:kicad/kicad-11.0-releases`, and add an element to the `eda-modules` ApplicationSet. The
two then coexist as `module load kicad/10.0.6` and `module load kicad/11.x`, which is the
whole reason this is a module rather than a package baked into the desktop image.

### ⚠ Renovate does not track this version

The project rule is that every version define is annotated so Renovate manages it. **This one
is not**, because Renovate's configured regexes cover neither a PPA source nor a bare version
string inside a Dockerfile shell assertion. Nothing will tell you when 10.0.7 ships — you
find out from a build failure, which on a module that rebuilds rarely may be months later.

Until that gap is closed, check the PPA by hand when you touch this app:

```bash
curl -s https://ppa.launchpadcontent.net/kicad/kicad-10.0-releases/ubuntu/dists/resolute/main/binary-amd64/Packages.gz \
  | gunzip | awk '/^Package: kicad$/{p=1} p&&/^Version:/{print $2; exit}'
```

## Typing `kicad` instead of `module-kicad-kicad`

**It already works — that is what the `cli_entries` in `module.yaml` are for.** After
`module load kicad/10.0.6`, plain `kicad`, `eeschema`, `pcbnew`, `gerbview` and `kicad-cli`
are all on PATH, and the module's own load message lists them. The unprefixed `kicad` wrapper
is byte-identical to `module-kicad-kicad` and execs the same `/usr/bin/kicad` in the same
container — it opens the GUI, not a CLI.

```bash
module load kicad/10.0.6
kicad            # the GUI, no prefix
```

The difference is only WHERE each wrapper lives, and the prefix on the desktop one is
deliberate:

| wrapper | lives in | on PATH |
| ------- | -------- | ------- |
| `kicad` | `~/.local/module-bin/kicad/10.0.6/` | only while the module is loaded |
| `module-kicad-kicad` | `~/.local/bin/` | **always**, in every shell |

⚠ Do NOT "fix" the prefix by dropping it. `~/.local/bin` is on PATH whether or not any module
is loaded, so an unprefixed `kicad` there would shadow a system binary permanently and
collide with a second major (`kicad-9`) the moment one exists — which is the whole reason
this is a module. The prefixed names exist so the Applications-menu tiles can have stable
launcher paths without owning the bare tool name globally.

## Verifying it

On the remote-desktop, as an ordinary user:

```bash
module avail                      # lists kicad/10.0.6
module load kicad/10.0.6
kicad-cli version                 # -> 10.0.6
```

Then the real test: open a `.kicad_sch` in the GUI and confirm the symbols **resolve**. A page
of question marks means the library packages did not make it into the image.

The GUI tiles (KiCad, Schematic Editor, PCB Editor, Gerber Viewer) appear in the desktop's
Applications menu. `kicad-cli` is the only entry that works without a DISPLAY; the other
`cli_entries` are GUIs listed for typing convenience while the module is loaded.

If a GUI starts and shows no window, read
`memory: qt-gui-modules-need-a-session-bus` before debugging the app — a created-but-unmapped
window is an X-cookie or dbus problem, not a KiCad one. The entrypoint starts a session bus
for exactly this reason.

## Rebuilding

The CI gate skips the build when the tag is already in the lab-local registry. To force one:
set `FORCE_REBUILD: "1"` in the `.gitlab-ci.yml` **inside `build-files-configmap.yaml`** (the
trigger mirrors the ConfigMap, not the sibling file), sync the app, and remove it again
afterwards.

⚠ The sibling `Dockerfile` / `module.yaml` in this directory and their copies inside
`build-files-configmap.yaml` are kept in sync **by hand**. Editing only the sibling changes
nothing that reaches GitLab.
