# Zammad

Open-source helpdesk / ticketing, at `https://zammad.<tld>`, SSO via Authentik.

Upstream chart `zammad` **17.0.1** (appVersion 7.1.2-0004) from
<https://zammad.github.io/zammad-helm>. Chart source is checked out at
`external/git_zammad_zammad-helm` — read it there rather than guessing values.

## Licensing: no paid edition needed

Self-hosted Zammad is AGPL-3.0 and **functionally complete**. There is no
feature-gated enterprise build: SSO (OIDC/SAML), LDAP, knowledge base, SLAs,
reporting, CTI and all channels ship in the free version.

- Self-hosted "subscriptions" (Business/Enterprise/Corporation, €2,999–€9,999/yr)
  buy **support response times and a service-request quota only** — no code.
- The per-agent tiers (Starter/Professional/Plus, €7/€16/€25) are **Zammad Cloud**
  hosting plans. Their feature gating does not apply to a self-hosted install.

## All chart subcharts are disabled

`values.yaml` disables every bundled dependency; we run the backing services
ourselves:

| Service | Ours | Why not the subchart |
|---|---|---|
| postgres | `postgres.yaml` (CNPG) | CNPG gives barman S3 WAL archiving + PITR; no subchart does |
| redis | `datastores.yaml` | matches the zulip/nextcloud/gitlab pattern |
| memcached | `datastores.yaml` | same |
| elasticsearch | `datastores.yaml` (official Elastic image) | upstream's subchart is **still Bitnami**, kept alive only by a `bitnamilegacy/elasticsearch` override + `global.security.allowInsecureImages: true` |
| minio | not used — Hetzner S3 | upstream's subchart has the same `bitnamilegacy` problem, and its future is undecided |

Upstream's Bitnami exit is tracked in
[zammad-helm#353](https://github.com/zammad/zammad-helm/issues/353) (3 of 5 done:
memcached/redis/postgres moved to CloudPirates; elasticsearch + minio still
Bitnami). [#398](https://github.com/zammad/zammad-helm/issues/398) is weighing
dropping MinIO entirely in favour of bring-your-own-S3 — which is what we already
do, so we land on the right side of it either way.

Because every subchart is off, upstream subchart churn cannot break us. Chart
bumps must still be reviewed for renames of the `zammadConfig.*` connection keys
we *do* use — do not auto-merge Renovate here.

## Gotchas

**Redis needs a password.** Unlike every other redis in this repo. The chart
hardcodes `REDIS_URL` as `redis://:$(REDIS_PASSWORD)@host:port` but only emits the
`REDIS_PASSWORD` env var when a password is configured
(`_helpers.tpl` → `zammad.env.redisVariables`). With an empty password Rails
receives the **literal string** `$(REDIS_PASSWORD)`. Hence the sealed
`zammad-redis-auth` secret and `--requirepass` in `datastores.yaml`.

**OIDC is a PUBLIC client with PKCE — no client secret.** A deliberate deviation
from the repo's confidential-client convention. Zammad's admin UI has no
client-secret field, and its docs require client authentication disabled at the
OP; authentik's own Zammad guide specifies client type Public with subject mode
"Based on the User's Email". So there is no `oidc-client-secret-sealed.yaml`.

**OIDC breaks under `letsencrypt-staging`.** Zammad requires both systems reachable
over HTTPS and **does not support untrusted/self-signed chains**, with no
`NODE_EXTRA_CA_CERTS`-style escape hatch. This app therefore has no
`staging-ca.yaml` and assumes `certIssuerType: letsencrypt-prod`. Flipping the
cluster back to staging will break SSO login.

**OIDC settings live in the database**, not env vars, so `postsync-oidc.yaml` sets
them with `rails r Setting.set(...)`. It runs at `sync-wave: 10`, after
`authentik-provider.yaml` at wave 0 — ArgoCD orders hooks within a phase by
`argocd.argoproj.io/sync-wave`. ⚠ It does NOT order them by
`argocd.argoproj.io/hook-weight`; that annotation does not exist and is silently ignored
(gitops-engine `syncwaves.Wave()` reads sync-wave, else `helm.sh/hook-weight`, else 0), so
while this file said otherwise both jobs were in fact running in wave 0 together.
PostSync hooks only run on a sync that actually changes something, so a
no-op sync will skip them.

**OpenSearch is not an option.** Zammad version-checks the search engine and
rejects OpenSearch 2.x. It needs Elasticsearch >= 7.8, < 10.

**Elasticsearch runs with `node.store.allow_mmap=false`** to avoid needing the
`vm.max_map_count >= 262144` host sysctl (which would require a privileged
initContainer on every node). The perf cost is irrelevant at helpdesk volumes.
`fsGroup: 1000` is required — the Elastic image runs as uid 1000 and will not
start on a root-owned Longhorn mount.

**No `priorityClassName` support.** The chart exposes none (verified: zero hits in
`values.yaml` and `templates/`), so the four Zammad Deployments run at priority 0
and are the first evicted under memory pressure. Our own CNPG cluster and the
redis/memcached/elasticsearch StatefulSets do set `standard`.

**Singletons.** `zammadConfig.scheduler.replicas` and `.websocket.replicas` are
capped at 1 cluster-wide — do not raise them. `railsserver` and `nginx` scale.

**Chart 17.0.0 upgrade trap** (not relevant to a fresh install, but to the next
bump across it): deployment `selector.matchLabels` changed and selectors are
immutable, so upgrading from <17 requires
`kubectl delete deployment --selector app.kubernetes.io/name=zammad --cascade=orphan`
first. 17.0.0 also renamed the bundled redis service
`<release>-redis-master` → `<release>-redis`, so pre-17 config examples found
online are wrong.

## Storage

Ticket attachments go to Hetzner S3 (`edgecloudinfra-zammad`) via the `S3_URL`
secret, not to the database and not to an RWX volume. `s3-buckets-job.yaml`
creates that bucket plus `edgecloudinfra-zammad-pg` for CNPG barman.

To switch storage backend later, change it in the admin panel, then migrate:

```
kubectl -n zammad exec deploy/zammad-railsserver -- \
  bundle exec rails r "Store::File.move('File', 'S3')"
```

## Bootstrap

`zammad-autowizard` seals an initial admin so a cluster recreate needs no manual
getting-started wizard. Real users arrive through Authentik OIDC with
`auth_third_party_auto_link_at_inital_login` enabled; the autowizard account is
the break-glass admin. Its password is recoverable from the sealed file
(`autowizard-password` key).

**The chart does NOT run the autowizard** — `postsync-oidc.yaml` does. The
chart's init job gates on `rails r 'puts User.any?'`
(`templates/configmap-init.yaml:15`), but `db:seed` always creates the
`nicole.braun` sample user, so that test is already true on a fresh database and
the autowizard branch is never taken. Left to the chart alone, Zammad serves the
getting-started wizard instead of the login page and **SSO is unreachable even
though `auth_openid_connect` is true** — the symptom is
`/api/v1/getting_started` returning `{"auto_wizard":true}`. The PostSync job
therefore calls `AutoWizard.setup` and sets `system_init_done` itself, skipping
both when an admin already exists.

## Login page is OIDC-only

`postsync-oidc.yaml` sets `user_show_password_login: false` and
`user_create_account: false`, so `https://zammad.<tld>/` offers **only** the
"Sign in using Authentik" button — no username/password form, no self-registration.

**This cannot lock you out.** The login view computes

```coffee
user_show_password_login = @C('user_show_password_login') || _.isEmpty(@auth_providers)
```

(`app/assets/javascripts/app/views/login.jst.eco:13`), so the password form
**reappears automatically** if OIDC is ever unregistered. While it is hidden, the
break-glass path is `https://zammad.<tld>/#admin_password_auth`, which mails an
admin a one-time login link — the login page links to it in its own text. The
autowizard admin (password in the sealed `zammad-autowizard`) is the account to
use there.

`user_create_account` only takes effect while the password form is shown, but it
is set explicitly because this is a staff helpdesk, not open registration.

## The Authentik tile cannot deep-link into the OIDC flow

The tile's `meta_launch_url` is `https://zammad.<tld>` — the app root — and that
is the only thing it *can* be. There is **no URL that starts the OIDC flow
directly**:

```
GET  /auth/openid_connect  -> 404
POST /auth/openid_connect  -> 302 (needs a CSRF token from a rendered page)
```

OmniAuth 2.x removed GET initiation deliberately (CVE-2015-9284: login CSRF), and
Zammad does not re-enable it — `config/initializers/omniauth.rb` sets no
`allowed_request_methods`. So a tile click necessarily lands on Zammad's own login
page, which then POSTs with a valid token.

This is why hiding the password form matters: it turns that unavoidable
intermediate page into a single SSO button rather than a login form that looks
like the tile "forgot" where to go.

## GitLab issue linking

Paste a GitLab issue URL into a ticket and the sidebar shows live issue metadata
(title, state, assignees, milestone, labels). Provisioned by
`postsync-gitlab-integration.yaml` (sync-wave 20, after the OIDC job at 10).

**Read-only.** `lib/gitlab/linked_issue.rb` runs one GraphQL query per issue URL.
It cannot create issues or sync ticket→issue. Hence the `read_api` scope.

**The endpoint is the PUBLIC URL — deliberately, not an oversight.**
`https://gitlab.<tld>/api/graphql`, not the internal
`http://gitlab-webservice-default.gitlab.svc...` this repo uses everywhere else.
`lib/gitlab/linked_issue.rb` rejects a link unless
`client.endpoint.include?(host)`, where `host` is parsed from the URL the *user
pasted*. Since users paste `gitlab.<tld>`, an internal endpoint would reject
**every** link. This relies on `gitlab.<tld>` resolving in-cluster
(`coredns-gitlab-internal`). The job still uses the internal URL for its
readiness and token-validation calls, where no such host check applies.

**URL format users must paste:**

```
https://gitlab.<tld>/<group>/<project>/-/issues/<n>       # nested groups are fine
https://gitlab.<tld>/<group>/<project>/-/work_items/<n>   # also accepted
```

The regex is anchored with `$`, so a permalink carrying an anchor or query string
(`.../-/issues/1#note_5`) is **rejected** with "Invalid GitLab issue link format".
Worth knowing before someone reports it as a bug — copying a comment permalink is
the natural way to hit this. GitLab 19 also canonicalises `/-/issues/<n>` to
`/-/work_items/<n>`; Zammad follows that redirect and reports the new URL via its
`url_replacements` map, so the stored link may differ from what was pasted.

**Access model.** A dedicated GitLab service account `zammad-integration` holds
**Reporter (20) on the top-level `deployments` group**, inherited by all current
and future projects. All projects are private, so a service account has no
implicit read access and this grant is mandatory; **Guest is not enough** to read
issues on a private project. `Users::ServiceAccounts::CreateService` creates the
account with `external: true`, which is fine — external only removes *implicit*
access, and explicit membership still grants reads (verified: all 7 private
projects visible through the token).

**The token must be long-lived, and it also EXPIRES — hence the CronJob.**
`app/services/service/ticket/external_references/issue_tracker/fetch_metadata.rb`
re-reads `gitlab_config[:api_token]` and queries GitLab on **every ticket view**,
so the mint-then-revoke pattern used by `zulip/postsync-gitlab-webhook.yaml`
would break the feature. But a *non-expiring* PAT is impossible on GitLab 19:
`expires_at: nil` fails validation ("Expiration date can't be blank") and a
callback caps any lifetime at
`PersonalAccessToken::MAX_PERSONAL_ACCESS_TOKEN_LIFETIME_IN_DAYS` = **365 days**,
*even though this instance's `max_personal_access_token_lifetime` is `nil`*
(verified on 19.2.0 — asking for `nil` silently yielded a 365-day token).

So the credential has to be rotated, and nothing triggers an ArgoCD sync when a
token quietly expires. That is why this ships as **two workloads running the same
script**: a PostSync Job (wires a fresh cluster immediately) and a **daily
CronJob** (rotates). The script renews once the token is within
`RENEW_BEFORE_DAYS` (30) of expiry, so there are ~30 daily opportunities to
rotate *while the old token still works* — no outage window.

The repo rule "never store a GitLab PAT" still holds: the token lives in Zammad's
*database*, never in git.

**Idempotency.** The script reads the token Zammad has stored and re-mints only
if it fails to resolve to `zammad-integration` (via `/api/v4/user`) or is near
expiry (via `/api/v4/personal_access_tokens/self`, which a `read_api` token may
call on itself). Steady-state runs write nothing — important, because
unconditional re-minting would invalidate the token in active use and every
ticket view would error during the gap. It still self-heals on a fresh database,
a revoked token, a deleted service account, or a hand-pasted personal token.

**Settings are GitOps-authoritative**: editing the integration in Zammad's admin
UI is overwritten on the next *changing* sync (a no-op sync skips PostSync hooks,
so drift can persist a while). `verify_ssl: true` requires `letsencrypt-prod` —
same failure class as the OIDC note above.

**Interaction with `gitlab/cronjob-bootstrap-groups.yaml`**: that CronJob reaps
stale direct members of `deployments`, but only those at `access_level: OWNER`,
and it skips `u.bot?` (a `service_account` user *is* `bot?`). A Reporter service
account is doubly out of scope. If that reaper is ever widened beyond Owners, it
must keep skipping service accounts or it will break this integration every
15 minutes.

## Verifying a deployment

```
curl -s https://zammad.<tld>/api/v1/getting_started
#   {"auto_wizard":true}                  -> wizard not completed, SSO hidden
#   {"error":"Authentication required"}   -> setup done, login page live

curl -s -X POST -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://zammad.<tld>/auth/openid_connect
#   302 -> .../auth/failure?message=...InvalidAuthenticityToken&strategy=openid_connect
#   is CORRECT: OmniAuth 2.x requires POST + CSRF, so a plain GET returning 404
#   is expected and is NOT evidence that OIDC is broken.

# login page shape (expect false / false / true)
kubectl -n zammad exec deploy/zammad-railsserver -- bundle exec rails r "
  %w[user_show_password_login user_create_account auth_openid_connect].each { |n|
    puts n + ' = ' + Setting.get(n).to_s }"

# GitLab integration — settings landed (token value never printed)
kubectl -n zammad exec deploy/zammad-railsserver -- bundle exec rails r "
  c = Setting.get('gitlab_config').to_h
  puts 'integration = ' + Setting.get('gitlab_integration').to_s
  puts 'endpoint    = ' + c['endpoint'].to_s
  puts 'verify_ssl  = ' + c['verify_ssl'].to_s
  puts 'token_set   = ' + (c['api_token'].to_s.empty? ? 'NO' : 'yes')"

# GitLab integration — end-to-end against a real issue (THE feature).
# An empty issues array means the service account cannot SEE that project (a
# membership problem); a bad token RAISES instead.
kubectl -n zammad exec deploy/zammad-railsserver -- bundle exec rails r "
  gl = GitLab.new(**Setting.get('gitlab_config').to_h.symbolize_keys)
  pp gl.issues_by_urls(['https://gitlab.<tld>/<group>/<project>/-/issues/1'])"

# GitLab side: service account, its token, and the inherited grant
kubectl -n gitlab exec deploy/gitlab-toolbox -c toolbox -- gitlab-rails runner "
  u = User.find_by(username: 'zammad-integration')
  puts u.user_type.to_s + ' ' + u.state
  puts u.personal_access_tokens.active.map { |t| [t.name, t.scopes, t.expires_at].inspect }
  puts Group.find_by_full_path('deployments').members.find_by(user_id: u.id)&.access_level.inspect"
# expect: service_account active / [\"zammad-issue-linking\", [\"read_api\"], nil] / 20
```
