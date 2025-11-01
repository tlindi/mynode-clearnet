#!/bin/bash

source /usr/share/mynode/mynode_device_info.sh
source /usr/share/mynode/mynode_app_versions.sh

set -x
set -e

echo "[INFO] ==================== INSTALLING APP ===================="

# Variables
export APP=clearnet

# Create working directory for .service (even if unused)
mkdir -p /opt/mynode/${APP}

# Directory setup
export APP_DATADIR=/mnt/hdd/mynode/${APP}
export MYNODE_CERTDIR=/home/bitcoin/.mynode/https
export LETSENCRYPT_HOME=/etc/letsencrypt
export LETSENCRYPT_DATADIR=$APP_DATADIR/letsencrypt
export LETSENCRYPT_BACKUPDIR=/mnt/hdd/mynode/${APP}_backup/letsencrypt

# Install required packages only if not already installed
for pkg in certbot python3-certbot python3-certbot-nginx; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "[INFO] Installing missing package $pkg..."
        if ! apt -y install "$pkg"; then
            echo "[ERROR] Failed to install $pkg" >&2
            exit 1
        fi
    else
        echo "[SKIP] Package $pkg already installed"
    fi
done

# Handle existing LETSENCRYPT_HOME
if [ -L "$LETSENCRYPT_HOME" ]; then
    target=$(readlink -f "$LETSENCRYPT_HOME")
    if [ "$target" = "$LETSENCRYPT_DATADIR" ]; then
        echo "[SKIP] $LETSENCRYPT_HOME already points to $LETSENCRYPT_DATADIR"
    else
        echo "[ERROR] $LETSENCRYPT_HOME is a symlink to $target, not $LETSENCRYPT_DATADIR. Aborting." >&2
        exit 1
    fi

elif [ -d "$LETSENCRYPT_HOME" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    backup_file="$LETSENCRYPT_BACKUPDIR/${APP}-letsencrypt-backup-$ts.tgz"
    mkdir -p "$LETSENCRYPT_BACKUPDIR"

    if [ ! -e "${LETSENCRYPT_BACKUPDIR}.org" ]; then
        cp -va "$LETSENCRYPT_HOME" "${LETSENCRYPT_BACKUPDIR}.org"
        echo "[INFO] Saved original letsencrypt to ${LETSENCRYPT_BACKUPDIR}.org"
    else
        echo "[SKIP] Original backup already exists at ${LETSENCRYPT_BACKUPDIR}.org"
    fi

    if ! tar -czf "$backup_file" -C "$(dirname "$LETSENCRYPT_HOME")" "$(basename "$LETSENCRYPT_HOME")"; then
        echo "[ERROR] Failed to create tar archive $backup_file" >&2
        exit 1
    else
        echo "[INFO] Created backup archive $backup_file"
    fi

    if [ -e "$LETSENCRYPT_DATADIR" ]; then
        echo "[ERROR] Destination $LETSENCRYPT_DATADIR already exists. Aborting to avoid nested move." >&2
        exit 1
    fi

    mkdir -p "$(dirname "$LETSENCRYPT_DATADIR")"

    if ! mv "$LETSENCRYPT_HOME" "$LETSENCRYPT_DATADIR"; then
        echo "[ERROR] Failed to move $LETSENCRYPT_HOME to $LETSENCRYPT_DATADIR" >&2
        exit 1
    fi

    if ! ln -s "$LETSENCRYPT_DATADIR" "$LETSENCRYPT_HOME"; then
        echo "[ERROR] Failed to link $LETSENCRYPT_HOME to $LETSENCRYPT_DATADIR" >&2
        exit 1
    fi

    echo "[INFO] Replaced $LETSENCRYPT_HOME with symlink to $LETSENCRYPT_DATADIR"
fi

# Fetch HTTPS domain
HTTPS_DOMAIN=$( { cat "$APP_DATADIR/https_domain"; } 2>/dev/null ) || {
    echo "[ERROR] HTTPS_DOMAIN file missing at $APP_DATADIR/https_domain" >&2
    exit 1
}

HTTPS_BASE_CERT=$(hostname).${HTTPS_DOMAIN}

#
# Helper functions
#

# Get public IP by querying multiple services; if they disagree return non-zero and log UNCERTAIN.
get_public_ip() {
    local services=( "https://ifconfig.co" "https://icanhazip.com" "https://ipinfo.io/ip" )
    local ips=()
    for s in "${services[@]}"; do
        ip=$(curl -s --max-time 5 "$s" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$ip" ]; then
            ips+=("$ip")
            echo "[INFO] public check $s -> $ip"
        else
            echo "[WARN] public check $s returned empty"
        fi
    done

    # unique set
    readarray -t unique_ips < <(printf "%s\n" "${ips[@]}" | sort -u)
    if [ "${#unique_ips[@]}" -eq 0 ]; then
        echo "[ERROR] Could not determine public IP from any service"
        return 2
    elif [ "${#unique_ips[@]}" -gt 1 ]; then
        echo "[UNCERTAIN-PUBLIC-IP] Services reported differing public IPs: ${unique_ips[*]}"
        return 3
    else
        PUBLIC_IP="${unique_ips[0]}"
        echo "[INFO] Determined public IP: ${PUBLIC_IP}"
        return 0
    fi
}

# Resolve a hostname to one or more IPs. Prefer getent; fallback to host.
# Returns newline-separated IPs or nothing on failure.
resolve_host_ips() {
    local host="$1"
    local ips=()
    if command -v getent >/dev/null 2>&1; then
        while read -r ip _; do
            [ -n "$ip" ] && ips+=("$ip")
        done < <(getent ahosts "$host" 2>/dev/null | awk '{print $1 " " $2}' | uniq)
    fi

    if [ "${#ips[@]}" -eq 0 ] && command -v host >/dev/null 2>&1; then
        while read -r line; do
            ip=$(echo "$line" | awk '/has address/ {print $4}')
            [ -n "$ip" ] && ips+=("$ip")
        done < <(host "$host" 2>/dev/null || true)
    fi

    if [ "${#ips[@]}" -gt 0 ]; then
        # unique and stable ordering
        printf "%s\n" "${ips[@]}" | sort -u
        return 0
    fi

    return 1
}

# Simple cached resolver wrapper to avoid repeated DNS queries (global cache).
declare -A RESOLVE_CACHE
get_resolved_ips_cached() {
    local name="$1"
    if [ -n "${RESOLVE_CACHE[$name]+set}" ]; then
        # stored as '|' separated string, convert back to newlines for callers
        IFS='|' read -r -a parts <<< "${RESOLVE_CACHE[$name]}"
        for p in "${parts[@]}"; do
            [ -n "$p" ] && printf "%s\n" "$p"
        done
        return 0
    fi

    local out
    out=$(resolve_host_ips "$name" 2>/dev/null || true)
    if [ -n "$out" ]; then
        # store as single-line with | separating items
        RESOLVE_CACHE[$name]="${out//$'\n'/'|'}"
        printf "%s\n" "$out"
        return 0
    fi

    # store empty to avoid repeated attempts
    RESOLVE_CACHE[$name]=""
    return 1
}

# Check that a required primary name resolves and matches public IP.
# returns 0 on success, non-zero on failure.
check_primary_domain() {
    local fqdn="$1"
    local resolved_ips=()
    while IFS= read -r ip; do
        [ -n "$ip" ] && resolved_ips+=("$ip")
    done < <(get_resolved_ips_cached "$fqdn" || true)

    if [ "${#resolved_ips[@]}" -eq 0 ]; then
        echo "[NON-RESOLVED-PRIMARY] $fqdn"
        return 1
    else
        echo "[RESOLVES-OK-PRIMARY] $fqdn -> ${resolved_ips[*]}"
    fi

    for rip in "${resolved_ips[@]}"; do
        if [ "$rip" = "$PUBLIC_IP" ]; then
            echo "[PRIMARY-MATCH] $fqdn resolves to the public IP (${PUBLIC_IP})"
            return 0
        fi
    done

    echo "[PRIMARY-NO-MATCH] $fqdn resolves to ${resolved_ips[*]} which does not match public IP ${PUBLIC_IP}"
    return 2
}

# Helper: check for MX records for a domain.
# Uses `host -t MX` if available, falls back to `dig +short MX`.
# Returns 0 if at least one MX record found, non-zero otherwise.
check_mx_for_domain() {
    local domain="$1"
    if command -v host >/dev/null 2>&1; then
        # host -t MX example output: "example.com mail is handled by 10 mx.example.com."
        out=$(host -t MX "$domain" 2>/dev/null || true)
        if [ -n "$out" ] && ! echo "$out" | grep -qi "has no MX record"; then
            # if output contains "mail is handled" or lines with MX then accept
            if echo "$out" | grep -qi "mail is handled by\|MX\|has MX record"; then
                return 0
            fi
        fi
    fi

    if command -v dig >/dev/null 2>&1; then
        out=$(dig +short MX "$domain" 2>/dev/null || true)
        if [ -n "$out" ]; then
            return 0
        fi
    fi

    return 1
}

# Fetch contact email from APP_DATADIR/https_domain_contact and validate.
# If valid and the contact domain has MX records, set CONTACT_EMAIL to that value.
# Otherwise fall back to info@${HTTPS_DOMAIN}.
get_contact_email() {
    local contact_file="$APP_DATADIR/https_domain_contact"
    local default_contact="info@${HTTPS_DOMAIN}"

    CONTACT_EMAIL=""
    if [ -f "$contact_file" ]; then
        # read first non-empty line, trim whitespace and CR
        CONTACT_EMAIL=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p}' "$contact_file" | tr -d '\r\n')
    fi

    if [ -z "$CONTACT_EMAIL" ]; then
        CONTACT_EMAIL="$default_contact"
        echo "[INFO] No contact file or empty; using default contact $CONTACT_EMAIL"
        return 0
    fi

    # basic email format check
    if ! echo "$CONTACT_EMAIL" | grep -Eq '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$'; then
        echo "[WARN] Contact email '$CONTACT_EMAIL' looks invalid; falling back to $default_contact"
        CONTACT_EMAIL="$default_contact"
        return 0
    fi

    # ensure the contact domain has MX records
    CONTACT_DOMAIN="${CONTACT_EMAIL#*@}"
    if check_mx_for_domain "$CONTACT_DOMAIN"; then
        echo "[INFO] Using contact email from $contact_file -> $CONTACT_EMAIL (MX ok for $CONTACT_DOMAIN)"
        return 0
    else
        echo "[WARN] Contact email domain '$CONTACT_DOMAIN' has no MX records; falling back to $default_contact"
        CONTACT_EMAIL="$default_contact"
        return 0
    fi
}

# Verify list of candidate fqdn's: check DNS resolvability and whether resolved IP(s) match the public IP.
# Logs statuses and returns matched domains via global HTTPS_HOSTS array.
# Optimized: uses RESOLVE_CACHE and skips duplicate candidate lines quickly.
verify_and_filter_domains() {
    local candidates=("$@")
    HTTPS_HOSTS=()
    RESOLVE_CACHE=()

    # obtain public IP (and check consistency)
    if ! get_public_ip; then
        return 1
    fi

    # Require both HTTPS_BASE_CERT and HTTPS_DOMAIN to be resolvable and match PUBLIC_IP.
    if ! check_primary_domain "${HTTPS_BASE_CERT}"; then
        echo "[ERROR] Required primary name ${HTTPS_BASE_CERT} failed verification. Aborting."
        return 2
    fi
    if ! check_primary_domain "${HTTPS_DOMAIN}"; then
        echo "[ERROR] Required primary name ${HTTPS_DOMAIN} failed verification. Aborting."
        return 3
    fi

    # Use associative to avoid duplicates
    declare -A seen
    for fqdn in "${candidates[@]}"; do
        # skip duplicates quickly
        if [ -n "${seen[$fqdn]+set}" ]; then
            echo "[SKIP-DUP] $fqdn (duplicate entry)"
            continue
        fi
        seen[$fqdn]=1

        # resolve (cached)
        resolved_ips=()
        while IFS= read -r ip; do
            [ -n "$ip" ] && resolved_ips+=("$ip")
        done < <(get_resolved_ips_cached "$fqdn" || true)

        if [ "${#resolved_ips[@]}" -eq 0 ]; then
            echo "[NON-RESOLVED] $fqdn"
            continue
        else
            echo "[RESOLVES-OK] $fqdn -> ${resolved_ips[*]}"
        fi

        # check if any resolved ip equals public ip
        match_found=false
        for rip in "${resolved_ips[@]}"; do
            if [ "$rip" = "$PUBLIC_IP" ]; then
                match_found=true
                break
            fi
        done

        if [ "$match_found" = true ]; then
            echo "[MATCH] $fqdn resolves to the public IP (${PUBLIC_IP})"
            HTTPS_HOSTS+=("$fqdn")
        else
            echo "[IGNORED] $fqdn resolves to ${resolved_ips[*]} which does not match public IP ${PUBLIC_IP}"
        fi
    done

    return 0
}

# Obtain certs and create symlinks for the certificate. Ensure HTTPS_BASE_CERT is always the primary cert name,
# and HTTPS_DOMAIN is second on the -d list. Only a single certbot invocation is performed here.
obtain_and_link_cert() {
    local matched=("$@")
    if [ "${#matched[@]}" -eq 0 ]; then
        echo "[ERROR] No domains to request certificates for. Aborting certbot run."
        return 1
    fi

    # Ensure HTTPS_BASE_CERT is present (verify step enforces, but double-check)
    present=false
    for d in "${matched[@]}"; do
        if [ "$d" = "$HTTPS_BASE_CERT" ]; then
            present=true
            break
        fi
    done
    if [ "$present" = false ]; then
        echo "[ERROR] ${HTTPS_BASE_CERT} is not among matched domains; refusing to proceed because HTTPS_BASE_CERT must be primary."
        return 2
    fi

    # Build ordered unique domain list: HTTPS_BASE_CERT first, HTTPS_DOMAIN second, then other matched hosts (de-duplicated).
    declare -A in_order
    ordered=()
    ordered+=("$HTTPS_BASE_CERT"); in_order["$HTTPS_BASE_CERT"]=1
    ordered+=("$HTTPS_DOMAIN"); in_order["$HTTPS_DOMAIN"]=1

    for d in "${matched[@]}"; do
        # skip if already in ordered
        [ "${in_order[$d]+set}" ] && continue
        in_order["$d"]=1
        ordered+=("$d")
    done

    # Build certbot args
    domain_args=()
    for d in "${ordered[@]}"; do
        domain_args+=("-d" "$d")
    done

    # dry-run check (single file presence switches dry-run)
    DRY_RUN_FLAG=()
    if [ -f "$APP_DATADIR/certbot_dry_run" ]; then
        DRY_RUN_FLAG+=(--dry-run)
        echo "[INFO] certbot will run in --dry-run mode due to presence of $APP_DATADIR/certbot_dry_run"
    fi

    # fetch contact email (uses https_domain_contact if valid and MX exists; otherwise default info@${HTTPS_DOMAIN})
    get_contact_email

    primary_cert_name="${HTTPS_BASE_CERT}"
    LE_CERT_PATH="$LETSENCRYPT_HOME/live/${primary_cert_name}"

    echo "[INFO] Requesting certificates with ordered domains: ${ordered[*]}"
    # single certbot invocation only, using CONTACT_EMAIL
    if ! certbot certonly --nginx --non-interactive --agree-tos "${DRY_RUN_FLAG[@]}" -m "$CONTACT_EMAIL" --http-01-port 18080 "${domain_args[@]}"; then
        echo "[ERROR] certbot failed to obtain certificates for ${primary_cert_name}" >&2
        return 3
    fi

    if [ -d "$LE_CERT_PATH" ] && [ -e "$LE_CERT_PATH/fullchain.pem" ] && [ -e "$LE_CERT_PATH/privkey.pem" ]; then
        echo "[INFO] Successfully obtained certs for ${primary_cert_name} at $LE_CERT_PATH"
    else
        echo "[ERROR] certbot did not produce expected files at $LE_CERT_PATH" >&2
        return 4
    fi

    # Create symlinks in MYNODE_CERTDIR for the cert files using HTTPS_BASE_CERT (primary_cert_name).
    mkdir -p "$MYNODE_CERTDIR"
    if [ -L "$MYNODE_CERTDIR/${primary_cert_name}.crt" ] || [ -e "$MYNODE_CERTDIR/${primary_cert_name}.crt" ]; then
        echo "[WARN] ${MYNODE_CERTDIR}/${primary_cert_name}.crt already exists. Skipping symlink creation for crt."
    else
        ln -s "$LE_CERT_PATH/fullchain.pem" "$MYNODE_CERTDIR/${primary_cert_name}.crt"
        echo "[INFO] Created symlink for ${primary_cert_name}.crt"
    fi

    if [ -L "$MYNODE_CERTDIR/${primary_cert_name}.key" ] || [ -e "$MYNODE_CERTDIR/${primary_cert_name}.key" ]; then
        echo "[WARN] ${MYNODE_CERTDIR}/${primary_cert_name}.key already exists. Skipping symlink creation for key."
    else
        ln -s "$LE_CERT_PATH/privkey.pem" "$MYNODE_CERTDIR/${primary_cert_name}.key"
        echo "[INFO] Created symlink for ${primary_cert_name}.key"
    fi

    return 0
}

#
# Build candidate list: always include HTTPS_BASE_CERT and HTTPS_DOMAIN first,
# then append host entries from hosts file (comments allowed with #).
#
DOMAINS=(
    "${HTTPS_BASE_CERT}"
    "${HTTPS_DOMAIN}"
)

# Read extra hostnames from single canonical file name http_hosts (comments allowed).
HTTP_HOSTS_FILE="$APP_DATADIR/http_hosts"
if [ -f "$HTTP_HOSTS_FILE" ]; then
    echo "[INFO] Reading extra hostnames from $HTTP_HOSTS_FILE"
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        # Trim leading/trailing whitespace
        line=$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Skip empty or full-line comments
        case "$line" in
            ""|\#*) continue ;;
        esac
        # Remove inline comment starting with '#'
        host="${line%%#*}"
        # Trim trailing/leading whitespace again after removing comment
        host=$(echo "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$host" ] && continue

        # If host is a short name (no dot), treat as subdomain and append .${HTTPS_DOMAIN}
        if ! echo "$host" | grep -q '\.'; then
            host="${host}.${HTTPS_DOMAIN}"
        fi

        DOMAINS+=("$host")
    done < "$HTTP_HOSTS_FILE"
else
    echo "[INFO] No $HTTP_HOSTS_FILE file found; only using ${HTTPS_BASE_CERT} and ${HTTPS_DOMAIN}"
fi

#
# Verify candidate domains and filter to ones that are resolvable and match public IP.
# Require HTTPS_BASE_CERT and HTTPS_DOMAIN to succeed — abort if either fails.
#
if ! verify_and_filter_domains "${DOMAINS[@]}"; then
    echo "[ERROR] Verification failed (required primary names must verify and/or public IP detection failed). Aborting."
    exit 1
fi

# HTTPS_HOSTS contains only domains that resolved and matched public IP.
if [ "${#HTTPS_HOSTS[@]}" -eq 0 ]; then
    echo "[INFO] No matched domains to request certificates for. Exiting without running certbot."
    exit 0
fi

# Ensure HTTPS_BASE_CERT is primary and HTTPS_DOMAIN is second; request certificates for matched hosts
if ! obtain_and_link_cert "${HTTPS_HOSTS[@]}"; then
    echo "[ERROR] Certificate obtain/linking failed." >&2
    exit 1
fi

echo "[INFO] =================== DONE INSTALLING APP ================="