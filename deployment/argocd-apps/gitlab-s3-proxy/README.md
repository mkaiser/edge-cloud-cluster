# gitlab-s3-proxy — lab-pinned TCP proxy to the appliance S3 endpoint

GitLab runs in the cloud; its CI-artifacts object store lives on the TrueNAS appliance at the
Bielefeld lab. **Cloud pods cannot address `192.168.1.0/24`.** This proxy is the one supported
way across that boundary.

```
GitLab webservice / Workhorse / Sidekiq (cloud pod)
        │  pod network (VXLAN over WireGuard)
        ▼
gitlab-s3-proxy  (pod pinned to ecc/fileserver-lan)
        │  lab LAN
        ▼
fs-1.ad.base.internal:30304   (SeaweedFS, TrueNAS app)
```

## Why this shape, and not the three obvious alternatives

**Why a real pod, not an `ExternalName` Service.** Envoy Gateway builds no upstream cluster for
an ExternalName backend: the route reports `Accepted=True, ResolvedRefs=True` and every request
500s. That defect previously took out prometheus, longhorn and alertmanager. A selector-less
Service with hand-written EndpointSlices does not help either — the *client* node still has to
route to `192.168.1.x`, and cloud nodes cannot.

**Why not fix the routing instead.** Measured 2026-09-02: the lab prefix is already advertised
and approved, and it is already in the cloud CP's peer `AllowedIPs`. But tailscaled does not
program it into WireGuard while `RouteAll` is off, and adding the kernel route by hand is not
enough — the packets are dropped. The only switch is `--accept-routes`, which also installs
`10.0.0.0/23` over `tailscale0` (verified: it is in table 52 on every accept-routes node) and
would move etcd peer traffic onto the mesh, where the peer certs' SANs do not match. That
hazard is unarmed *today* only because there is exactly one cloud CP advertising the prefix; it
arms the moment a second CP joins. Not a switch to flip for a storage endpoint.

**Why layer 4, not layer 7.** S3 requests are SigV4-signed and the signature covers the `Host`
header. An HTTP proxy that rewrites `Host` invalidates every request. This proxy never parses
HTTP — it forwards bytes — so `Host`, the signature, and multipart semantics all pass through
untouched.

## TLS: terminated by the appliance, not here

Deliberately **pure TCP passthrough**: the TLS session is between GitLab and the appliance.

Two consequences, and both are requirements on the *other* side:

1. **The appliance certificate must carry the name GitLab dials** —
   `gitlab-s3-proxy.gitlab-s3-proxy.svc.cluster.local` — as a SAN. Mint it through
   `deployment/argocd-infra/truenas/certificate-job.yaml`, which already manages appliance
   certificates.
2. **GitLab must trust that certificate.** Append its CA to `global.certificates.customCAs` in
   `deployment/argocd-apps/gitlab/values.yaml` — the list already exists there (it carries
   `gitlab-trusted-ca` for Authentik OIDC). The chart mounts the bundle into the **workhorse**
   container as well as Rails, which is what matters: Workhorse performs the upload.

Terminating TLS here instead was considered and rejected: it would mean copying the shared
`wildcard-tls` leaf into this namespace, which then goes stale at every 90-day renewal unless
something re-copies it. Passthrough has no such coupling.

## The endpoint name, and why `proxy_download` must stay `true` for now

The `endpoint` in GitLab's artifacts connection is used for two different things:

- Workhorse's **upload** target — a cloud pod, so it must resolve to this Service; and
- the host of every **presigned download URL** when `proxy_download: false`.

A `.svc.cluster.local` name works for the first and is useless for the second — a browser or a
lab client cannot resolve it. So while the endpoint is this Service name, **leave
`artifacts.proxy_download: true`** (the chart default), which streams downloads back through
Workhorse and therefore works for every audience.

Switching to `proxy_download: false` — worth doing, because it is what makes lab downloads fast
— requires first giving the endpoint a **public** name plus split-horizon DNS: cloud pods
resolving it to this Service, lab resolvers to the appliance's LAN address, and the public A
record to the Gateway. Same name in all three, or the presigned signatures break. That work is
tracked in `plans/old/gitlab-storage-placement.md` §6.1; do not do half of it.

## Limits worth knowing before debugging it

- **The readiness probe proves only that nginx is listening.** It does not check the appliance.
  A dead or absent backend looks perfectly healthy here and fails at connect time, per request.
  That is deliberate — this pod has no business deciding the appliance is down — but it means
  *this app being Healthy says nothing about artifacts working*. The alert on the artifacts
  endpoint (plan WP7a) is what covers that, not this probe.
- **The upstream hostname is resolved by nginx at startup**, once, and nginx exits with
  `[emerg] host not found in upstream` if it fails. `fs-1.ad.base.internal` is served by
  samba-ad, which comes up later than this app, so on the ecc193 bring-up the proxy
  crash-looped 15 times before AD DNS was ready. A `wait-for-dns` initContainer now holds the
  pod until the name resolves, so nginx starts once, when it can succeed. If you see this
  again it is AD DNS, not the proxy.
- **`proxy_timeout` is 1 hour.** Multi-GB multipart parts over a link whose lab→cloud direction
  measures ~4.9 MB/s take a long time; a short idle timeout truncates them mid-part. Do not
  lower it without measuring against a real EDA-sized artifact.
- **Single replica.** Two replicas would be harmless (it is stateless), but a second replica
  buys nothing while the backend is one appliance, and it doubles the connections that a
  restart drops.
- **Reachability is fenced by a CiliumNetworkPolicy** to the `gitlab` namespace. Cilium runs
  `enable-policy=default`, so it denies only where a policy *selects* the pod: if
  `networkpolicy.yaml` is removed, this becomes a cluster-wide open path to the appliance's S3
  endpoint with no error anywhere.
