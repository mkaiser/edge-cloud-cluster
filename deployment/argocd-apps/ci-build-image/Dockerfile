# The CI build image: buildah AND skopeo in one image.
#
# WHY IT EXISTS: no maintained upstream image ships both (verified 2026-09-02).
#   quay.io/buildah/stable   buildah 1.43.2 + curl 8.18.0, NO skopeo
#   quay.io/podman/stable    podman + curl, NEITHER buildah NOR skopeo
# so this cannot be a one-line image swap in the six pipelines — a derived image is the
# only way to have both. Measured: 673 MB vs the 635 MB base, i.e. ~38 MB for skopeo.
#
# WHAT USES IT: every image-building pipeline in this repo (the three EDA modules,
# remote-desktop's base image, ollama, vllm). They need buildah to BUILD and skopeo to
# ASK A REGISTRY WHETHER A TAG EXISTS — the recover-or-rebuild gate that decides between
# "skip", "copy the archived image back" and "rebuild for hours".
#
# ⚠ This image is NOT built with itself. Its own pipeline runs on the plain
# quay.io/buildah/stable below and keeps a curl-based gate; anything else is a
# bootstrap loop that a cluster recreate cannot break out of.
#
# renovate: tracked by "Container image tags" regex (docker datasource)
FROM quay.io/buildah/stable:v1.43.2

# skopeo comes from the same Fedora repos the base is built from, so it is the build of
# skopeo that matches this image's containers/image and containers/storage libraries.
# `dnf clean all` keeps the added layer at the ~38 MB the plan measured.
#
# The version check is the acceptance test, run at BUILD time: an image that reaches the
# registry without a working skopeo would break every consumer's gate at once, and the
# consumers are exactly the pipelines whose failure mode is "rebuild for hours, silently".
RUN dnf -y install skopeo \
 && dnf clean all \
 && rm -rf /var/cache/dnf \
 && buildah --version \
 && skopeo --version \
 && curl --version | head -1
