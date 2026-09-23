# XWiki deployment notes

## OIDC property names (traps)

| Property | Correct | Wrong |
|---|---|---|
| Client ID | `oidc.clientid` (all lowercase) | `oidc.clientId` → ignored, falls back to instance UUID |
| Scope | `oidc.clientid=openid,profile,email,groups` (comma-separated) | space-separated → parsed as one token, "openid" not found |
| Redirect URI (Authentik) | `/oidc/authenticator/callback` | `/authenticator/callback` |

## SSL with letsencrypt-staging

The JVM does not trust the staging CA → OIDC metadata fetch fails with `SSLHandshakeException`.

**Workaround (values.yaml):** `cluster.enabled: true` injects shell code into `start.sh` via the
`cluster.jgroups.kube_ping.url` value. The code after the first `;` runs before Tomcat and creates
`/data/cacerts-custom.jks` (system cacerts + letsencrypt staging roots). `javaOpts` points the JVM
at this file. Idempotent: skipped if the file already exists.

**Switch to production certs:** set `certIssuerType: letsencrypt-prod` in `project_settings.ts`,
run `updateConfigFromProjectSettings.sh`, then remove the `cluster:` block and `javaOpts` from `values.yaml`.

`oidc.insecure=true` claims to skip TLS but does NOT reliably disable SSL cert validation for the
metadata discovery call — do not rely on it as a staging workaround.

## First-cluster flow (automated by postsync-extensions.yaml)

1. Pod starts → `xwiki.authentication.authclass` set but OIDC JARs not yet in classpath →
   `ClassNotFoundException` logged, XWiki falls back to default auth (users get 401).
2. PostSync installs OIDC via Extension Manager (`extensionAction=continue`, not `install`).
3. PostSync deletes `xwiki-0` (RBAC in same file) → pod restarts, OIDC JARs load from extension cache.
4. PostSync runs Groovy via REST to: deny view for `XWikiGuest` (no anonymous access),
   add `testadmin` to `XWikiAdminGroup` (if user exists from a prior OIDC login).

## Admin rights — managed entirely in Authentik

`oidc.groups.mapping: "XWiki.XWikiAdminGroup=xwiki-oidc-admins"` — on every OIDC login, XWiki
syncs group membership from Authentik. Members of `xwiki-oidc-admins` in Authentik are automatically
in `XWikiAdminGroup` in XWiki. No per-user setup needed.

To make someone a XWiki admin: add them to the `xwiki-oidc-admins` group in Authentik.
Takes effect on their next login.

## Extension install via Extension Manager (no REST API)

The REST endpoint `/rest/wikis/xwiki/extensions/installed/` is **not available** in the standard
XWiki Docker image. Use the admin web UI flow:

```
POST /bin/admin/XWiki/XWikiPreferences?extensionSection=extensions&extensionId=...
     &extensionVersion=...&extensionNamespace=wiki:xwiki&section=XWiki.Extensions
Body: extensionAction=continue&form_token=<from data-xwiki-form-token attr>
→ 302 to progress page, poll for extension-item-installed
```
