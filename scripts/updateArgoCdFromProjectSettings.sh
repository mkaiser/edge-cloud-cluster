# Updates testNN subdomain, GitHub repo URL, and cert issuer from project_settings.ts in ArgoCD and other deployment manifests.

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
    sed -nE "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

extract_ts_cluster_number() {
    local key="$1"
    sed -nE "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

extract_ts_github_url() {
    sed -nE "s/^[[:space:]]*repoUrl[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

cd "$REPO_ROOT"

rollout_type=$(sed -nE 's/.*rolloutType:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
cert_issuer_type=$(sed -nE 's/.*certIssuerType:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
base_domain=$(extract_ts_cluster_string "baseDomain")
test_number=$(extract_ts_cluster_number "testNumber")
test_prefix=$(extract_ts_cluster_string "testSubdomainPrefix")
github_repo_url=$(extract_ts_github_url)

if [ -z "$base_domain" ]; then
    echo "Could not determine base domain from project_settings.ts (expected cluster.baseDomain)."
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

if [ -z "$test_number" ]; then
    test_number="0"
fi

if [ -z "$test_prefix" ]; then
    test_prefix="test"
fi

if [ "$rollout_type" = "Testing" ]; then
    test_subdomain="${test_prefix}${test_number}"
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

mapfile -t deployment_files < <(find "$REPO_ROOT/deployment" -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.yaml.template" -o -name "*.yml.template" -o -name "*.disable" \))

if [ ${#deployment_files[@]} -eq 0 ]; then
    echo "No deployment manifest files found under $REPO_ROOT/deployment"
    exit 1
fi

echo "Updating all testNN. occurrences to '$tld'."

# Replace all testNN. subdomain patterns with current test number
TEST_NUMBER="$test_number" perl -pi -e 's/\btest[0-9]{2}\./test$ENV{TEST_NUMBER}./g' "${deployment_files[@]}"

# Also update root level README
if [ -f "$REPO_ROOT/README.md" ]; then
    TEST_NUMBER="$test_number" perl -pi -e 's/\btest[0-9]{2}\./test$ENV{TEST_NUMBER}./g' "$REPO_ROOT/README.md"
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

# Discover prior base domains from existing testNN.<domain> hostnames and migrate them.
mapfile -t discovered_old_domains < <(
    grep -RhoE '([*A-Za-z0-9-]+\.)*test[0-9]{2}\.[A-Za-z0-9.-]+' "$REPO_ROOT/deployment" "$REPO_ROOT/README.md" 2>/dev/null \
        | sed -E 's/^.*test[0-9]{2}\.//' \
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
    OLD_DOMAIN="$old_domain" TLD="$tld" BASE_DOMAIN="$base_domain" perl -pi -e '
        my $old = quotemeta($ENV{OLD_DOMAIN});
        s/(test[0-9]{2})\.$old/$ENV{TLD}/g;
        s/\b$old\b/$ENV{BASE_DOMAIN}/g;
    ' "${deployment_files[@]}"

    if [ -f "$REPO_ROOT/README.md" ]; then
        OLD_DOMAIN="$old_domain" TLD="$tld" BASE_DOMAIN="$base_domain" perl -pi -e '
            my $old = quotemeta($ENV{OLD_DOMAIN});
            s/(test[0-9]{2})\.$old/$ENV{TLD}/g;
            s/\b$old\b/$ENV{BASE_DOMAIN}/g;
        ' "$REPO_ROOT/README.md"
    fi
done

if [ -f "$REPO_ROOT/deployment/opendesk-apps/charts/opendesk/values.yaml" ]; then
    TLD="$tld" perl -pi -e 's#^(\s*domain:\s*")[^"]*(".*)$#$1$ENV{TLD}$2#; s#^(\s*mailDomain:\s*")[^"]*(".*)$#$1$ENV{TLD}$2#' "$REPO_ROOT/deployment/opendesk-apps/charts/opendesk/values.yaml"
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
echo "Applied cert issuer '$normalized_cert_issuer_type', TLD '$tld', and GitHub repo URL '$github_repo_url'."
echo "Changed files:"
git --no-pager diff --name-only -- deployment project_settings.ts | sed '/^$/d' || true
