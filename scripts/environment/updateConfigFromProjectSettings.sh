#!/bin/bash
# Updates subdomain/TLD, GitHub repo URL, cert issuer, and targetRevision in ArgoCD and deployment manifests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

extract_ts_string() {
    local key="$1"
    sed -nE "s/^const[[:space:]]+${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

extract_ts_github_url() {
    sed -nE "s/.*gitRepoUrl[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

# Extract a `key: "value"` field (object property, e.g. network.meshRange).
extract_ts_field() {
    local key="$1"
    sed -nE "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$PROJECT_SETTINGS" | head -n1
}

cd "$REPO_ROOT"

rollout_type=$(sed -nE 's/.*rolloutType:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
cert_issuer_type=$(sed -nE 's/.*certIssuerType:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
base_domain=$(extract_ts_string "baseDomain")
subdomain=$(extract_ts_string "subdomain")
github_repo_url=$(extract_ts_github_url)

# Network ranges/addresses — single source of truth is project_settings.ts network{}.
mesh_range=$(extract_ts_field "meshRange")
subnet_range=$(extract_ts_field "subnetRange")
private_range=$(extract_ts_field "privateRange")
network_gateway=$(extract_ts_field "gateway")
kube_vip=$(extract_ts_field "vip")
# tailscalePort is an unquoted numeric field — pinned tailscaled --port = firewall rule.
tailscale_port=$(sed -nE 's/^[[:space:]]*tailscalePort[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$PROJECT_SETTINGS" | head -n1)
# meshRange is the source-of-truth literal (a `const`, not a network{} field).
[ -n "$mesh_range" ] || mesh_range=$(sed -nE 's/^const[[:space:]]+meshRange[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
# cp0MeshIp = first host of meshRange (cp0 joins the mesh first). Derived here exactly as
# project_settings.ts does (firstHostOf), so it can never drift from meshRange.
cp0_mesh_ip=$(printf '%s' "$mesh_range" | sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/[0-9]+$#\1.1#')
# cpMeshIps = CP mesh IPs in join order (cp0/cp1/cp2 = .1/.2/.3, sequential allocation).
# Published as the k3s-api.ts.internal A-record set so the agent LB fails over across CPs.
mesh_octets=$(printf '%s' "$mesh_range" | sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/[0-9]+$#\1#')
cp_mesh_ip_0="${mesh_octets}.1"
cp_mesh_ip_1="${mesh_octets}.2"
cp_mesh_ip_2="${mesh_octets}.3"
for _nv in mesh_range:"$mesh_range" subnet_range:"$subnet_range" \
           private_range:"$private_range" network_gateway:"$network_gateway" \
           kube_vip:"$kube_vip" cp0_mesh_ip:"$cp0_mesh_ip"; do
    if [ -z "${_nv#*:}" ]; then
        echo "Could not determine network.${_nv%%:*} from project_settings.ts."
        exit 1
    fi
done

if [ -z "$base_domain" ]; then
    echo "Could not determine baseDomain from project_settings.ts."
    exit 1
fi

if [ -z "$subdomain" ]; then
    echo "Could not determine subdomain from project_settings.ts."
    exit 1
fi

if [ -z "$github_repo_url" ]; then
    echo "Could not determine gitRepoUrl from project_settings.ts."
    exit 1
fi

if [[ "$github_repo_url" =~ ^git@github\.com:([^/[:space:]]+/[^[:space:]]+)\.git$ ]]; then
    github_repo_slug="${BASH_REMATCH[1]}"
else
    echo "Unsupported github.repoUrl format '$github_repo_url' (expected git@github.com:owner/repo.git)."
    exit 1
fi

if [ "$rollout_type" = "Testing" ]; then
    tld="${subdomain}.${base_domain}"
else
    tld="$base_domain"
fi

if [ -z "$cert_issuer_type" ]; then
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
    find "$REPO_ROOT/deployment" -type f \
        \( -name "*.yaml" -o -name "*.yml" -o -name "*.yaml.template" -o -name "*.yml.template" -o -name "*.disable" \)
)

if [ ${#deployment_files[@]} -eq 0 ]; then
    echo "No deployment manifest files found under $REPO_ROOT/deployment"
    exit 1
fi

echo "Updating subdomain references to '$tld'."

# Replace stale <prefix>.<baseDomain> hostnames with the current subdomain.
SUBDOMAIN="$subdomain" BASE_DOMAIN="$base_domain" perl -pi -e '
    my $bd = quotemeta($ENV{BASE_DOMAIN});
    my $sub = $ENV{SUBDOMAIN};
    s/\b([*A-Za-z0-9-]+\.)[A-Za-z-]+[0-9]+\.$bd/${1}$sub.$ENV{BASE_DOMAIN}/g;
    s/\b[A-Za-z-]+[0-9]+\.$bd/$sub.$ENV{BASE_DOMAIN}/g;
' "${deployment_files[@]}"

# Replace any other stale hostname under the base domain with the current subdomain.
SUBDOMAIN="$subdomain" BASE_DOMAIN="$base_domain" perl -pi -e '
    my $bd = quotemeta($ENV{BASE_DOMAIN});
    my $sub = $ENV{SUBDOMAIN};
    s/\b([A-Za-z0-9-]+\.)[A-Za-z0-9-]+\.$bd/${1}$sub.$ENV{BASE_DOMAIN}/g;
    s/\b([A-Za-z0-9-]+)\.$bd/$sub.$ENV{BASE_DOMAIN}/g;
' "${deployment_files[@]}"

# Also update root level README
if [ -f "$REPO_ROOT/README.md" ]; then
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

echo "Updating GitHub repo URL occurrences in deployment manifests to '$github_repo_url'."

GITHUB_REPO_URL="$github_repo_url" perl -pi -e 's#git\@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git#$ENV{GITHUB_REPO_URL}#g' "${deployment_files[@]}"

if [ -f "$REPO_ROOT/README.md" ]; then
    # Keep README generic for reuse across repositories.
    perl -pi -e 's#git\@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git#git@github.com:owner/repo.git#g' "$REPO_ROOT/README.md"
fi

# Keep RENOVATE_REPOSITORIES aligned with github.repoUrl (owner/repo only).
GITHUB_REPO_SLUG="$github_repo_slug" perl -0777 -pi -e 's#(-\s*name:\s*RENOVATE_REPOSITORIES\s*\n\s*value:\s*")[^"]+(")#$1$ENV{GITHUB_REPO_SLUG}$2#gms' "${deployment_files[@]}"

if [ -f "$REPO_ROOT/deployment/apps/gitlab/values.yaml" ]; then
    TLD="$tld" perl -pi -e 's#^(\s*domain:\s*)\S+(\s*)$#$1$ENV{TLD}$2#' "$REPO_ROOT/deployment/apps/gitlab/values.yaml"
fi

# Self-service enrollment email-domain whitelist: company email domain = baseDomain
if [ -f "$REPO_ROOT/deployment/infrastructure/authentik/blueprint-enrollment.yaml" ]; then
    echo "Setting self-registration email-domain whitelist to '$base_domain'."
    BASE_DOMAIN="$base_domain" perl -pi -e 's/(\.lower\(\) != ")[^"]*(")/$1$ENV{BASE_DOMAIN}$2/' \
        "$REPO_ROOT/deployment/infrastructure/authentik/blueprint-enrollment.yaml"
fi

# Update escaped base domains in external-dns regex arguments
BASE_DOMAIN="$base_domain" perl -pi -e '
    my $escaped_base = $ENV{BASE_DOMAIN};
    $escaped_base =~ s/\./\\./g;
    s#(--regex-domain-exclusion=.*\\\.)[A-Za-z0-9-]+(?:\\\.[A-Za-z0-9-]+)+(\$)#$1$escaped_base$2#g;
' "${deployment_files[@]}"

issuer_files=(
    "$REPO_ROOT/deployment/infrastructure/argocd-infra/wildcard-certs.yaml"
    "$REPO_ROOT/deployment/infrastructure/kube-prometheus-stack/prometheus.yaml"
    "$REPO_ROOT/deployment/argocd-sync-waves/wave8-headscale.yaml"
    "$REPO_ROOT/deployment/apps/gitlab/values.yaml"
    "$REPO_ROOT/deployment/apps/gitlab/gitlab-tls-certificate.yaml"
    "$REPO_ROOT/deployment/infrastructure/authentik/values.yaml"
    "$REPO_ROOT/deployment/apps/nextcloud/values.yaml"
    "$REPO_ROOT/deployment/apps/nextcloud/collabora.yaml"
    "$REPO_ROOT/deployment/apps/xwiki/values.yaml"
    "$REPO_ROOT/deployment/apps/jitsi/values.yaml"
    "$REPO_ROOT/deployment/apps/rocketchat/values.yaml"
    "$REPO_ROOT/deployment/apps/ryax/haproxy-ingress.yaml"
    "$REPO_ROOT/deployment/infrastructure/longhorn/ingress.yaml"
    "$REPO_ROOT/deployment/apps/windows/values.yaml"
)

for file in "${issuer_files[@]}"; do
    [ -f "$file" ] || continue
    sed -i -E "s#(cert-manager.io/cluster-issuer:[[:space:]]*\")letsencrypt-(prod|staging)(\")#\1${normalized_cert_issuer_type}\3#g" "$file"
    sed -i -E "s#(cert-manager.io/cluster-issuer:[[:space:]]*)letsencrypt-(prod|staging)#\1${normalized_cert_issuer_type}#g" "$file"
done

if [ -f "$REPO_ROOT/deployment/infrastructure/argocd-infra/wildcard-certs.yaml" ]; then
    sed -i -E "s#(name:[[:space:]]*)letsencrypt-(prod|staging)#\1${normalized_cert_issuer_type}#g" "$REPO_ROOT/deployment/infrastructure/argocd-infra/wildcard-certs.yaml"
fi

# Ryax registry Certificate references the cluster issuer by issuerRef.name
if [ -f "$REPO_ROOT/deployment/apps/ryax/haproxy-ingress.yaml" ]; then
    sed -i -E "s#(name:[[:space:]]*)letsencrypt-(prod|staging)#\1${normalized_cert_issuer_type}#g" "$REPO_ROOT/deployment/apps/ryax/haproxy-ingress.yaml"
fi

# ArgoCD OIDC TLS verification
if [ -f "$REPO_ROOT/deployment/infrastructure/argocd-infra/values.yaml" ]; then
    if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then oidc_skip="false"; else oidc_skip="true"; fi
    sed -i -E "s#(oidc.tls.insecure.skip.verify:[[:space:]]*\")[^\"]*(\")#\1${oidc_skip}\2#" "$REPO_ROOT/deployment/infrastructure/argocd-infra/values.yaml"
fi

# Headplane (Node.js) OIDC TLS
if [ -f "$REPO_ROOT/deployment/infrastructure/headplane/headplane.yaml" ]; then
    if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then node_tls="1"; else node_tls="0"; fi
    NODE_TLS="$node_tls" perl -0777 -pi -e 's/(NODE_TLS_REJECT_UNAUTHORIZED\s*\n\s*value:\s*")[^"]*(")/$1$ENV{NODE_TLS}$2/s' "$REPO_ROOT/deployment/infrastructure/headplane/headplane.yaml"
fi

# Zulip OIDC backend TLS verification
if [ -f "$REPO_ROOT/deployment/apps/zulip/values.yaml" ]; then
    if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then zulip_verify="True"; else zulip_verify="False"; fi
    ZULIP_VERIFY="$zulip_verify" perl -0777 -pi -e 's/(SETTING_SOCIAL_AUTH_VERIFY_SSL:\s*")[^"]*(")/$1$ENV{ZULIP_VERIFY}$2/s' "$REPO_ROOT/deployment/apps/zulip/values.yaml"
fi

# Grafana generic_oauth backend TLS
if [ -f "$REPO_ROOT/deployment/infrastructure/kube-prometheus-stack/prometheus.yaml" ]; then
    if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then gf_skip="false"; else gf_skip="true"; fi
    sed -i -E "s#(tls_skip_verify_insecure:[[:space:]]*)(true|false)#\1${gf_skip}#" "$REPO_ROOT/deployment/infrastructure/kube-prometheus-stack/prometheus.yaml"
fi

# Jitsi OIDC adapter TLS
if [ -f "$REPO_ROOT/deployment/apps/jitsi/oidc-adapter.yaml" ]; then
    if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then jitsi_unsecure="false"; else jitsi_unsecure="true"; fi
    JITSI_UNSECURE="$jitsi_unsecure" perl -0777 -pi -e 's/(name:\s*ALLOW_UNSECURE_CERT\s*\n\s*value:\s*")[^"]*(")/$1$ENV{JITSI_UNSECURE}$2/s' "$REPO_ROOT/deployment/apps/jitsi/oidc-adapter.yaml"
fi

# curl insecure flag for PreSync jobs and CronJobs
if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then curl_insecure=""; else curl_insecure="-k"; fi
for curl_insecure_file in \
    "$REPO_ROOT/deployment/apps/gitlab/presync-wait-authentik-oidc.yaml" \
    "$REPO_ROOT/deployment/apps/gitlab-runner/presync-wait-authentik-oidc.yaml" \
    "$REPO_ROOT/deployment/apps/gitlab/cronjob-sync-admins.yaml" \
    "$REPO_ROOT/deployment/apps/zulip/cronjob-sync-users.yaml" \
    "$REPO_ROOT/deployment/apps/rocketchat/oauth-config.yaml" \
    "$REPO_ROOT/deployment/apps/nextcloud/cronjob-calendar-setup.yaml"; do
    if [ -f "$curl_insecure_file" ]; then
        CURL_INSECURE="$curl_insecure" perl -0777 -pi -e 's/(name:\s*CURL_INSECURE\s*\n\s*value:\s*")[^"]*(")/$1$ENV{CURL_INSECURE}$2/s' "$curl_insecure_file"
    fi
done

# Ryax TLS environment
if [ -f "$REPO_ROOT/deployment/apps/ryax/values.yaml" ]; then
    if [ "$normalized_cert_issuer_type" = "letsencrypt-prod" ]; then ryax_env="production"; else ryax_env="stg"; fi
    sed -i -E "s#^(    environment:)[[:space:]]+\S+(.*)#\1 ${ryax_env}\2#" "$REPO_ROOT/deployment/apps/ryax/values.yaml"
    echo "Updated Ryax TLS environment to: ${ryax_env}"
fi

# ---------------------------------------------------------------------------
# Network ranges/addresses: project_settings.ts network{} is the single source
# of truth. src/*.ts read it directly; YAML manifests can't, so rewrite the values
# here — driven by Renovate-style context anchors. Any manifest line carrying a
#   # project-settings: network.<key>
# trailing comment has its value (the CIDR/IP token before the comment) replaced
# with project_settings.ts network.<key>. This is structure-independent: adding the
# marker to a new line is all that's needed to keep it in sync. Supported keys are
# those exported below in NETWORK_VALUES.
# ---------------------------------------------------------------------------
echo "Updating network values from project_settings.ts via '# project-settings: network.<key>' anchors:"
echo "  meshRange='$mesh_range' subnetRange='$subnet_range' privateRange='$private_range' gateway='$network_gateway' vip='$kube_vip' cp0MeshIp='$cp0_mesh_ip' cpMeshIps=[$cp_mesh_ip_0,$cp_mesh_ip_1,$cp_mesh_ip_2]."

# key=value map consumed by the perl pass below. The indexed cpMeshIps[N] keys feed the
# k3s-api.ts.internal A-record SET in wave8-headscale.yaml (one record per control-plane).
NETWORK_VALUES=$(cat <<EOF
meshRange=$mesh_range
subnetRange=$subnet_range
privateRange=$private_range
gateway=$network_gateway
vip=$kube_vip
cp0MeshIp=$cp0_mesh_ip
cpMeshIps[0]=$cp_mesh_ip_0
cpMeshIps[1]=$cp_mesh_ip_1
cpMeshIps[2]=$cp_mesh_ip_2
tailscalePort=$tailscale_port
EOF
)

# Files carrying network anchors: all deployment manifests + the edge-provisioning
# scripts (separate placeholder pipeline, but the same anchor convention keeps their
# hardcoded ranges in sync). Globbed so new edge scripts are picked up automatically.
mapfile -t anchor_files < <(
    printf '%s\n' "${deployment_files[@]}"
    find "$REPO_ROOT/scripts/edge-provisioning" -maxdepth 1 -type f -name "*.sh" 2>/dev/null
    # Pulumi-deployed essential pods (cert-manager, sealed-secrets) live in src/*.ts,
    # not under deployment/. Their HA replica counts carry `// project-settings: ha.<key>`
    # anchors, so include these TS files in the HA passes below.
    printf '%s\n' "$REPO_ROOT/src/certmanager.ts" "$REPO_ROOT/src/sealedsecrets.ts"
)

# One pass over all anchored files. For each line with the anchor, replace the
# IPv4/CIDR token before the anchor comment with the value for that key.
NETWORK_VALUES="$NETWORK_VALUES" perl -i -pe '
    BEGIN {
        # Keys may be plain (meshRange) or indexed (cpMeshIps[0]); match both.
        %V = map { /^([\w\[\]]+)=(.*)$/ ? ($1 => $2) : () } split /\n/, $ENV{NETWORK_VALUES};
    }
    if (/# project-settings:\s*network\.([\w\[\]]+)/) {
        my $key = $1;
        if (exists $V{$key}) {
            my $val = $V{$key};
            if ($val =~ /^[0-9]+$/) {
                # Plain numeric value (e.g. tailscalePort): replace a bare integer token.
                s{([0-9]+)(\s*(?:["\x27])?\s*(?:[^#]*?)?#\s*project-settings:\s*network\.\Q$key\E)}{$val$2};
            } else {
                # Replace the IPv4 address or CIDR immediately preceding the anchor comment.
                s{([0-9]{1,3}(?:\.[0-9]{1,3}){3}(?:/[0-9]{1,2})?)(\s*(?:["\x27])?\s*(?:[^#]*?)?#\s*project-settings:\s*network\.\Q$key\E)}{$val$2};
            }
        }
    }
' "${anchor_files[@]}"

# ---------------------------------------------------------------------------
# HA replica counts + anti-affinity: derived from general.highAvailability and the
# per-key ha.replicas { min, max } map in project_settings.ts (single source of truth).
# Any line carrying `# project-settings: ha.<key>` (or `// …` in src/*.ts) has its
# integer rewritten to max (HA on) or min (HA off). Any line carrying
# `# project-settings: haAffinity.<key>` has its boolean set to highAvailability.
# Adding the anchor to a new line is all that's needed — structure-independent.
# ---------------------------------------------------------------------------
ha_enabled=$(perl -ne 'print "$1" and exit if /\bhighAvailability\s*:\s*(true|false)/' "$PROJECT_SETTINGS")
[ -n "$ha_enabled" ] || ha_enabled="false"

# Parse the ha.replicas map (region-gated to the `ha: {` … matching close) into a
# resolved KEY=INT map (max when HA, else min) and a KEY=BOOL affinity map.
HA_VALUES=$(HA_ON="$ha_enabled" perl -ne '
    $in = 1 if /^\s*ha:\s*\{/;
    if ($in && /^\s*(\w+)\s*:\s*\{\s*min:\s*(\d+)\s*,\s*max:\s*(\d+)\s*\}/) {
        my $v = ($ENV{HA_ON} eq "true") ? $3 : $2;
        print "$1=$v\n";
    }
    $in = 0 if $in && /^\s*\},\s*$/ && !/min:/;
' "$PROJECT_SETTINGS")

HA_AFFINITY=$(printf '%s\n' "$HA_VALUES" | sed -E "s/=[0-9]+$/=$ha_enabled/")

echo "Updating HA replica counts from project_settings.ts via '# project-settings: ha.<key>' anchors:"
echo "  highAvailability=$ha_enabled — resolved targets:"
printf '    %s\n' $HA_VALUES

# Pass 1 — replica/instances integer. Accepts both `#` (YAML) and `//` (src/*.ts) anchors.
HA_VALUES="$HA_VALUES" perl -i -pe '
    BEGIN { %V = map { /^(\w+)=(\d+)$/ ? ($1 => $2) : () } split /\n/, $ENV{HA_VALUES}; }
    if (m{(?:\#|//)\s*project-settings:\s*ha\.(\w+)\b}) {
        my $key = $1;
        if (exists $V{$key}) {
            my $val = $V{$key};
            s{((?:instances|replicas|replicaCount)\s*:\s*)(["\x27]?)\d+(["\x27]?)(.*?(?:\#|//)\s*project-settings:\s*ha\.\Q$key\E\b)}{$1$2$val$3$4};
        }
    }
' "${anchor_files[@]}"

# Pass 2 — anti-affinity boolean (enablePodAntiAffinity). Accepts `#` and `//` anchors.
HA_AFFINITY="$HA_AFFINITY" perl -i -pe '
    BEGIN { %A = map { /^(\w+)=(true|false)$/ ? ($1 => $2) : () } split /\n/, $ENV{HA_AFFINITY}; }
    if (m{(?:\#|//)\s*project-settings:\s*haAffinity\.(\w+)\b}) {
        my $key = $1;
        if (exists $A{$key}) {
            my $val = $A{$key};
            s{((?:enablePodAntiAffinity)\s*:\s*)(?:true|false)(.*?(?:\#|//)\s*project-settings:\s*haAffinity\.\Q$key\E\b)}{$1$val$2};
        }
    }
' "${anchor_files[@]}"

# ---------------------------------------------------------------------------
# S3 bucket names: project_settings.ts is the single source of truth.
# ---------------------------------------------------------------------------
cluster_name=$(perl -ne 'print "$1" and exit if /^const\s+clusterName\s*=\s*"([^"]+)"/' "$PROJECT_SETTINGS")

s3_base_endpoint=$(perl -ne 'print "$1\n" and exit if /baseEndpoint:\s*"([^"]+)"/' "$PROJECT_SETTINGS")
if [ -n "$s3_base_endpoint" ]; then
    s3_region=$(echo "$s3_base_endpoint" | cut -d. -f1)
    echo "Updating S3 endpoint to '$s3_base_endpoint' (region '$s3_region')..."
    grep -rIl "your-objectstorage.com" \
        "$REPO_ROOT/deployment" "$REPO_ROOT/scripts" 2>/dev/null \
        | grep -v "\.git" \
        | while IFS= read -r f; do
        S3EP="$s3_base_endpoint" S3RGN="$s3_region" perl -pi -e '
            s{[a-z0-9]+\.your-objectstorage\.com}{$ENV{S3EP}}g;
            s{(BucketLocation\s*=\s*")[a-z0-9]+"}{$1$ENV{S3RGN}"}g;
            s{(^\s*region:\s*)[A-Za-z0-9-]+(\s*$)}{$1$ENV{S3RGN}$2}mg;
        ' "$f"
    done
fi

extract_bucket_name() {
    CN="$cluster_name" perl -ne '
        if (/key:\s*"'"$1"'"\s*,\s*name:\s*"([^"]+)"/)  { print "$1\n"; exit }
        if (/key:\s*"'"$1"'"\s*,\s*name:\s*`([^`]+)`/)   { my $n=$1; $n =~ s/\$\{clusterName\}/$ENV{CN}/g; print "$n\n"; exit }
    ' "$PROJECT_SETTINGS"
}

etcd_bucket=$(extract_bucket_name etcd)
longhorn_bucket=$(extract_bucket_name longhornBackup)
gitlab_bucket=$(extract_bucket_name gitlab)
nextcloud_bucket=$(extract_bucket_name nextcloud)
headscale_bucket=$(extract_bucket_name headscale)
zulip_bucket=$(extract_bucket_name zulip)

replace_bucket_refs() {
    local suffix="$1" newname="$2"
    [ -n "$newname" ] || return 0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        SFX="$suffix" NEW="$newname" perl -pi -e '
            my $s = quotemeta($ENV{SFX}); my $n = $ENV{NEW};
            s{(s3://)[A-Za-z0-9._-]+-$s\b}{$1$n}g;
            s{^(\s*(?:bucket|tmpBucket):[ \t]+)[A-Za-z0-9._-]*-$s\b}{$1$n}mg;
            s{"[A-Za-z0-9._-]+-$s"}{"$n"}g;
        ' "$f"
    done < <(grep -rIl -- "-${suffix}" "$REPO_ROOT/deployment" "$REPO_ROOT/scripts/pulumi" 2>/dev/null || true)
}

replace_bucket_refs etcd            "$etcd_bucket"
replace_bucket_refs longhorn-backup "$longhorn_bucket"
replace_bucket_refs gitlab          "$gitlab_bucket"
replace_bucket_refs nextcloud       "$nextcloud_bucket"
replace_bucket_refs headscale       "$headscale_bucket"
replace_bucket_refs zulip           "$zulip_bucket"

echo "Applied S3 bucket names: etcd='$etcd_bucket' longhorn='$longhorn_bucket' gitlab='$gitlab_bucket' nextcloud='$nextcloud_bucket' headscale='$headscale_bucket'."

# Update targetRevision fields that carry a branch ref to the current checked-out branch.
current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ -n "$current_branch" ] && [ "$current_branch" != "HEAD" ]; then
    echo "Updating targetRevision placeholder values to current branch '$current_branch'..."
    BRANCH="$current_branch" perl -pi -e '
        if (/^(\s*targetRevision:\s*)([^\s#"]+)(\s*(#.*)?)$/) {
            my ($pre, $val, $rest) = ($1, $2, $3 // "");
            unless ($val =~ /^v?\d+\.\d/ || $val =~ /^[0-9a-f]{40}$/ || $val eq "HEAD") {
                s/^(\s*targetRevision:\s*)[^\s#"]+/$1$ENV{BRANCH}/;
            }
        } elsif (/^(\s*targetRevision:\s*)"([^"]+)"(\s*(#.*)?)$/) {
            my $val = $2;
            unless ($val =~ /^v?\d+\.\d/ || $val =~ /^[0-9a-f]{40}$/ || $val eq "HEAD") {
                s/^(\s*targetRevision:\s*)"[^"]+"/$1"$ENV{BRANCH}"/;
            }
        }
    ' "${deployment_files[@]}"
else
    echo "Could not determine current branch; skipping targetRevision update."
fi

echo "ArgoCD/deployment manifest update completed from project_settings.ts."
echo "Applied cert issuer '$normalized_cert_issuer_type', TLD '$tld', GitHub repo URL '$github_repo_url'"
echo "Changed files:"
git --no-pager diff --name-only -- deployment scripts/pulumi project_settings.ts | sed '/^$/d' || true
