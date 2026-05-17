# Updates subdomain/TLD, GitHub repo URL, cert issuer, and openDesk registration template DN from project_settings.ts in ArgoCD and other deployment manifests.

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_SETTINGS="$REPO_ROOT/project_settings.ts"

if [ ! -f "$PROJECT_SETTINGS" ]; then
    echo "Missing project settings file: $PROJECT_SETTINGS"
    exit 1
fi

if [ "$#" -ne 0 ]; then
    echo "Usage: $0"
    echo "Reads domain, GitHub repo URL, and cert issuer settings from project_settings.ts and updates deployment manifests."
    exit 1
fi

extract_ts_cluster_string() {
    local key="$1"
    # Look in top-level const definitions first (e.g., const baseDomain = "...")
    sed -nE "s/^const[[:space:]]+${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

extract_ts_cluster_number() {
    local key="$1"
    sed -nE "s/^const[[:space:]]+${key}[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

extract_ts_github_url() {
    sed -nE "s/.*gitRepoUrl[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

cd "$REPO_ROOT"

rollout_type=$(sed -nE 's/.*rolloutType:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
cert_issuer_type=$(sed -nE 's/.*certIssuerType:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
base_domain=$(extract_ts_cluster_string "baseDomain")
subdomain=$(extract_ts_cluster_string "subdomain")
github_repo_url=$(extract_ts_github_url)
registration_template_dn=""

if [ -z "$base_domain" ]; then
    echo "Could not determine base domain from project_settings.ts (expected const baseDomain or general.baseDomain)."
    exit 1
fi

if [ -z "$github_repo_url" ]; then
    echo "Could not determine github repo URL from project_settings.ts (expected github.repoUrl)."
    exit 1
fi

if [[ "$github_repo_url" =~ ^git@github\.com:([^/[:space:]]+/[^[:space:]]+)\.git$ ]]; then
    github_repo_slug="${BASH_REMATCH[1]}"
else
    echo "Unsupported github.repoUrl format '$github_repo_url' (expected git@github.com:owner/repo.git)."
    exit 1
fi

if [ -z "$subdomain" ]; then
    # Backward compatibility for older project_settings.ts fields
    subdomain_prefix=$(extract_ts_cluster_string "subdomainPrefix")
    subdomain_suffix=$(extract_ts_cluster_number "subdomainSuffix")
    if [ -z "$subdomain_suffix" ]; then
        subdomain_suffix=$(extract_ts_cluster_number "testNumber")
    fi
    if [ -z "$subdomain_prefix" ]; then
        subdomain_prefix="test"
    fi
    if [ -z "$subdomain_suffix" ]; then
        subdomain_suffix="0"
    fi
    subdomain="${subdomain_prefix}${subdomain_suffix}"
fi

legacy_prefixes="test"
if [[ "$subdomain" =~ ^([A-Za-z-]+)([0-9]+)$ ]]; then
    legacy_prefixes="test,${BASH_REMATCH[1]}"
fi
legacy_prefix_pattern=$(printf '%s' "$legacy_prefixes" | perl -pe 's/([^A-Za-z0-9_,])/\\$1/g; s/,/|/g')

if [ "$rollout_type" = "Testing" ]; then
    test_subdomain="$subdomain"
    tld="${test_subdomain}.${base_domain}"
else
    test_subdomain=""
    tld="$base_domain"
fi

if [ -z "$cert_issuer_type" ]; then
    # Fallback for computed certIssuerType values in project settings.
    if [ "$rollout_type" = "Testing" ]; then
        cert_issuer_type="letsencrypt-staging"
    else
        cert_issuer_type="letsencrypt-prod"
    fi
fi

normalized_cert_issuer_type="$cert_issuer_type"
case "$cert_issuer_type" in
    letsencrypt-production)
        normalized_cert_issuer_type="letsencrypt-prod"
        ;;
    letsencrypt-prod|letsencrypt-staging) ;;
    *)
        echo "Unsupported certIssuerType '$cert_issuer_type' in project settings."
        exit 1
        ;;
esac

echo "Using rolloutType: $rollout_type"
echo "Using TLD from project settings: $tld"
echo "Using cert issuer from project settings: $cert_issuer_type"
echo "Using normalized cert issuer for manifests: $normalized_cert_issuer_type"
echo "Using GitHub repo URL from project settings: $github_repo_url"
echo "Using GitHub repository slug for Renovate: $github_repo_slug"

mapfile -t deployment_files < <(
    find "$REPO_ROOT/deployment" "$REPO_ROOT/ryax_manual" -type f \
        \( -name "*.yaml" -o -name "*.yml" -o -name "*.yaml.template" -o -name "*.yml.template" -o -name "*.disable" \)
)

if [ ${#deployment_files[@]} -eq 0 ]; then
    echo "No deployment manifest files found under $REPO_ROOT/deployment"
    exit 1
fi

echo "Updating legacy subdomain prefixes to '$tld'."

# Replace all <legacyPrefix>N. patterns with current subdomain label.
SUBDOMAIN="$subdomain" LEGACY_PREFIXES="$legacy_prefixes" perl -pi -e '
    my @prefixes = grep { length } split /,/, $ENV{LEGACY_PREFIXES};
    my $alt = join("|", map { quotemeta($_) } @prefixes);
    if ($alt ne "") {
        s/\b(?:$alt)[0-9]+\./$ENV{SUBDOMAIN}./g;
    }
' "${deployment_files[@]}"

# Normalize any stale <prefixN>.<baseDomain> labels to the current subdomain,
# even if the old prefix is no longer known (e.g. after prefix renames).
SUBDOMAIN="$subdomain" BASE_DOMAIN="$base_domain" perl -pi -e '
    my $bd = quotemeta($ENV{BASE_DOMAIN});
    my $sub = $ENV{SUBDOMAIN};
    s/\b([*A-Za-z0-9-]+\.)[A-Za-z-]+[0-9]+\.$bd/${1}$sub.$ENV{BASE_DOMAIN}/g;
    s/\b[A-Za-z-]+[0-9]+\.$bd/$sub.$ENV{BASE_DOMAIN}/g;
' "${deployment_files[@]}"

# Normalize any other stale hostnames under the base domain, including plain
# subdomain names like gitlab.myecc.cape-project.eu -> gitlab.mycluster.cape-project.eu.
SUBDOMAIN="$subdomain" BASE_DOMAIN="$base_domain" perl -pi -e '
    my $bd = quotemeta($ENV{BASE_DOMAIN});
    my $sub = $ENV{SUBDOMAIN};
    s/\b([A-Za-z0-9-]+\.)[A-Za-z0-9-]+\.$bd/${1}$sub.$ENV{BASE_DOMAIN}/g;
    s/\b([A-Za-z0-9-]+)\.$bd/$sub.$ENV{BASE_DOMAIN}/g;
' "${deployment_files[@]}"

# Also update root level README
if [ -f "$REPO_ROOT/README.md" ]; then
    SUBDOMAIN="$subdomain" LEGACY_PREFIXES="$legacy_prefixes" perl -pi -e '
        my @prefixes = grep { length } split /,/, $ENV{LEGACY_PREFIXES};
        my $alt = join("|", map { quotemeta($_) } @prefixes);
        if ($alt ne "") {
            s/\b(?:$alt)[0-9]+\./$ENV{SUBDOMAIN}./g;
        }
    ' "$REPO_ROOT/README.md"

    SUBDOMAIN="$subdomain" BASE_DOMAIN="$base_domain" perl -pi -e '
        my $bd = quotemeta($ENV{BASE_DOMAIN});
        my $sub = $ENV{SUBDOMAIN};
        s/\b([*A-Za-z0-9-]+\.)[A-Za-z-]+[0-9]+\.$bd/${1}$sub.$ENV{BASE_DOMAIN}/g;
        s/\b[A-Za-z-]+[0-9]+\.$bd/$sub.$ENV{BASE_DOMAIN}/g;
    ' "$REPO_ROOT/README.md"

    SUBDOMAIN="$subdomain" BASE_DOMAIN="$base_domain" perl -pi -e '
        my $bd = quotemeta($ENV{BASE_DOMAIN});
        my $sub = $ENV{SUBDOMAIN};
        s/\b([A-Za-z0-9-]+\.)[A-Za-z0-9-]+\.$bd/${1}$sub.$ENV{BASE_DOMAIN}/g;
        s/\b([A-Za-z0-9-]+)\.$bd/$sub.$ENV{BASE_DOMAIN}/g;
    ' "$REPO_ROOT/README.md"
fi

# Discover and replace old GitHub URLs
echo "Updating GitHub repo URL occurrences in deployment manifests to '$github_repo_url'."

# Replace all git@github.com:owner/repo.git (or similar) URLs detected in deployment files
GITHUB_REPO_URL="$github_repo_url" perl -pi -e 's#git\@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git#$ENV{GITHUB_REPO_URL}#g' "${deployment_files[@]}"

if [ -f "$REPO_ROOT/README.md" ]; then
    # Keep README generic for reuse across repositories.
    perl -pi -e 's#git\@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git#git@github.com:owner/repo.git#g' "$REPO_ROOT/README.md"
fi

# Keep RENOVATE_REPOSITORIES aligned with github.repoUrl (owner/repo only).
GITHUB_REPO_SLUG="$github_repo_slug" perl -0777 -pi -e 's#(-\s*name:\s*RENOVATE_REPOSITORIES\s*\n\s*value:\s*")[^"]+(")#$1$ENV{GITHUB_REPO_SLUG}$2#gms' "${deployment_files[@]}"

# Discover prior base domains from existing <legacyPrefix>N.<domain> hostnames and migrate them.
mapfile -t discovered_old_domains < <(
    grep -RhoE "([*A-Za-z0-9-]+\.)*(${legacy_prefix_pattern})[0-9]+\.[A-Za-z0-9.-]+" "$REPO_ROOT/deployment" "$REPO_ROOT/README.md" 2>/dev/null \
        | sed -E "s/^.*(${legacy_prefix_pattern})[0-9]+\.//" \
        | sed -E 's/\.+$//' \
        | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
        | grep -E '^[A-Za-z0-9.-]+$' \
        | sort -u
)

for old_domain in "${discovered_old_domains[@]}"; do
    [ -n "$old_domain" ] || continue
    if [ "$old_domain" = "$base_domain" ]; then
        continue
    fi

    echo "Migrating domain references: $old_domain -> $base_domain"
    SUBDOMAIN="$subdomain" LEGACY_PREFIXES="$legacy_prefixes" OLD_DOMAIN="$old_domain" TLD="$tld" BASE_DOMAIN="$base_domain" perl -pi -e '
        my @prefixes = grep { length } split /,/, $ENV{LEGACY_PREFIXES};
        my $alt = join("|", map { quotemeta($_) } @prefixes);
        my $old = quotemeta($ENV{OLD_DOMAIN});
        if ($alt ne "") {
            s/((?:$alt)[0-9]+)\.$old/$ENV{TLD}/g;
        }
        s/\b$old\b/$ENV{BASE_DOMAIN}/g;
    ' "${deployment_files[@]}"

    if [ -f "$REPO_ROOT/README.md" ]; then
        SUBDOMAIN="$subdomain" LEGACY_PREFIXES="$legacy_prefixes" OLD_DOMAIN="$old_domain" TLD="$tld" BASE_DOMAIN="$base_domain" perl -pi -e '
            my @prefixes = grep { length } split /,/, $ENV{LEGACY_PREFIXES};
            my $alt = join("|", map { quotemeta($_) } @prefixes);
            my $old = quotemeta($ENV{OLD_DOMAIN});
            if ($alt ne "") {
                s/((?:$alt)[0-9]+)\.$old/$ENV{TLD}/g;
            }
            s/\b$old\b/$ENV{BASE_DOMAIN}/g;
        ' "$REPO_ROOT/README.md"
    fi
done

if [ -f "$REPO_ROOT/deployment/opendesk-apps/charts/opendesk/values.yaml" ]; then
    # domain  → full TLD (e.g. myecc.cape-project.eu) for cluster Ingress/portal routing
    # mailDomain → base domain only (e.g. cape-project.eu) so FROM address matches the
    #              SMTP relay auth account (opendesk-system@cape-project.eu).
    #              Hetzner relay silently discards mail where FROM subdomain ≠ auth domain.
    TLD="$tld" BASE_DOMAIN="$base_domain" perl -pi -e '
        s#^(\s*domain:\s*")[^"]*(".*)$#$1$ENV{TLD}$2#;
        s#^(\s*mailDomain:\s*")[^"]*(".*)$#$1$ENV{BASE_DOMAIN}$2#;
    ' "$REPO_ROOT/deployment/opendesk-apps/charts/opendesk/values.yaml"
fi

ldap_domain="dc=$(printf '%s' "$tld" | sed 's/\./,dc=/g')"
registration_template_dn="cn=openDesk User,cn=templates,cn=univention,${ldap_domain}"

# usertemplate lives in chart-overrides.yaml (mounted as --state-values-file), NOT in
# values.yaml overwrites, because the value contains spaces and commas which break
# --state-values-set argument parsing (shell word-split on space, helmfile splits on comma).
if [ -f "$REPO_ROOT/deployment/opendesk-cmp/chart-overrides.yaml" ]; then
    REGISTRATION_TEMPLATE_DN="$registration_template_dn" perl -pi -e 's#^(\s*usertemplate:\s*")[^"]*(".*)$#$1$ENV{REGISTRATION_TEMPLATE_DN}$2#' "$REPO_ROOT/deployment/opendesk-cmp/chart-overrides.yaml"
fi

if [ -f "$REPO_ROOT/deployment/gitlab/values.yaml" ]; then
    TLD="$tld" perl -pi -e 's#^(\s*domain:\s*)\S+(\s*)$#$1$ENV{TLD}$2#' "$REPO_ROOT/deployment/gitlab/values.yaml"
fi

# Update escaped base domains in external-dns regex arguments, e.g. anotherDomain\.de -> your-domain\.tld
BASE_DOMAIN="$base_domain" perl -pi -e '
    my $escaped_base = $ENV{BASE_DOMAIN};
    $escaped_base =~ s/\./\\./g;
    s#(--regex-domain-exclusion=.*\\\.)[A-Za-z0-9-]+(?:\\\.[A-Za-z0-9-]+)+(\$)#$1$escaped_base$2#g;
' "${deployment_files[@]}"

issuer_files=(
    "$REPO_ROOT/deployment/argocd/wildcard-certs.yaml"
    "$REPO_ROOT/deployment/kube-prometheus-stack/prometheus.yaml"
    "$REPO_ROOT/deployment/apps/wave4-headscale.yaml"
    "$REPO_ROOT/deployment/gitlab/values.yaml"
)

for file in "${issuer_files[@]}"; do
    [ -f "$file" ] || continue
    sed -i -E "s#(cert-manager.io/cluster-issuer:[[:space:]]*\")letsencrypt-(prod|staging)(\")#\1${normalized_cert_issuer_type}\3#g" "$file"
    sed -i -E "s#(cert-manager.io/cluster-issuer:[[:space:]]*)letsencrypt-(prod|staging)#\1${normalized_cert_issuer_type}#g" "$file"
done

if [ -f "$REPO_ROOT/deployment/argocd/wildcard-certs.yaml" ]; then
    sed -i -E "s#(name:[[:space:]]*)letsencrypt-(prod|staging)#\1${normalized_cert_issuer_type}#g" "$REPO_ROOT/deployment/argocd/wildcard-certs.yaml"
fi

echo "ArgoCD/deployment manifest update completed from project_settings.ts."
echo "Applied cert issuer '$normalized_cert_issuer_type', TLD '$tld', GitHub repo URL '$github_repo_url', and openDesk registration template DN '$registration_template_dn'."
echo "Changed files:"
git --no-pager diff --name-only -- deployment project_settings.ts | sed '/^$/d' || true
