# scripts/tailscale

Client-side helpers for joining the cluster's self-hosted headscale VPN from a
**Windows 11** machine. These run on the user's laptop, not in the cluster or the
devcontainer — hence PowerShell/batch rather than shell.

For the full joining procedure (Authentik `vpn-users` group, `tailscale up`, reaching the
lab fileserver) see `doc/vpn-user-access.md`. This directory only holds the pieces that
must execute on Windows.

| file | purpose |
| ---- | ------- |
| `Install-StagingCertRoots.ps1` | trust the Let's Encrypt **staging** roots, so `tailscale up` can complete its TLS handshake while the cluster issues staging certificates |
| `install-staging-cert-roots.bat` | wrapper for the above — handles execution policy and UAC elevation |

## Install-StagingCertRoots.ps1

```powershell
# from this directory, in Windows Terminal / cmd
install-staging-cert-roots.bat -Server vpn.<subdomain>.<domain>            # install (prompts for elevation)
install-staging-cert-roots.bat -Server vpn.<subdomain>.<domain> -Verify    # report only, no elevation
install-staging-cert-roots.bat -Server vpn.<subdomain>.<domain> -Remove    # undo
```

Or invoke PowerShell directly, from an **elevated** shell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StagingCertRoots.ps1 -Server vpn.<subdomain>.<domain>
```

### Why it is needed

While `certIssuerType` in `project_settings.ts` is `"letsencrypt-staging"`, every cluster
host serves a certificate from Let's Encrypt's staging CA, which no OS trusts. headscale is
healthy — `curl -k https://vpn.<tld>/health` returns 200 — but the Tailscale client aborts
on the handshake, and there is **no client-side `--insecure`** for `--login-server`.

The proper fix is switching the cluster to `letsencrypt-prod` (see the TLS section of
`CLAUDE.md`). This script is for when staging has to stay.

### ⚠ It is a genuinely unsafe trust decision

Let's Encrypt issues staging certificates to anyone for any name, without the validation
the production CA applies. Trusting these roots means **any holder of a staging certificate
can impersonate any HTTPS site to this machine**. Lab/dev machines only; run `-Remove` once
the cluster serves prod certs.

### ⚠ Trust the ROOT, not the root-looking intermediate

The chain the cluster serves is:

```
leaf (*.<subdomain>.<domain>)
  → (STAGING) Dastardly Durum YR1
  → (STAGING) Yonder Yam Root YR      ← says "Root", is NOT one
  → (STAGING) Pretend Pear X1         ← the actual trust anchor
```

`Yonder Yam Root YR` is served in the chain and named "Root", so it is the obvious thing to
grab — but it is an **intermediate** cross-signed by Pretend Pear X1, and installing it
establishes no trust. The script installs X1 (plus X2, `Bogus Broccoli`, the ECDSA
counterpart that does not anchor today's chain but is free to trust alongside).

Verified with `openssl verify`: fails against X1 with either intermediate alone, passes with
both.

Note the intermediate is `Dastardly Durum YR1`, **not** the `(STAGING) Artificial Apricot R3`
that older write-ups name — Let's Encrypt rotates staging intermediates. If the script
reports the roots installed but the server still does not validate, re-read the live chain
before assuming the script is wrong:

```
openssl s_client -connect vpn.<tld>:443 -servername vpn.<tld> -showcerts
```

### Thumbprints are pinned before import

Each root is checked against an expected SHA-1 **before** being trusted. Downloading a root
over TLS and trusting whatever arrives would be circular — the machine does not yet trust
the signing CA, which is the entire problem the script solves. A mismatch throws instead of
installing; if Let's Encrypt rotates a staging root, update the thumbprint in the script
against <https://letsencrypt.org/docs/staging-environment/>.

## install-staging-cert-roots.bat

Exists because the `.ps1` cannot be launched directly on a default Windows 11 install: script
execution is disabled (`PSSecurityException` — "die Ausführung von Skripts auf diesem System
ist deaktiviert") and writing the machine trust store needs Administrator. The wrapper passes
`-ExecutionPolicy Bypass` per-invocation (no machine-wide security change), detects whether it
is already elevated via `net session`, and otherwise re-launches through UAC with `-NoExit` so
the new window's output stays readable.

`-Verify` deliberately does **not** trigger a UAC prompt — it only reads the store and probes
the server.
