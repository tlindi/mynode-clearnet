#!/bin/bash
# install_clearnet.sh
# Reworked: compact verification functions, mandatory contact email validation (no fallback),
# single certbot invocation, HTTPS_BASE_CERT primary, HTTPS_DOMAIN second,
# dry-run toggle file support, DNS resolution caching, clear main flow.
# Updated: CNAME-following resolver, and added restore-or-create APP_DATADIR logic at start.

set -euo pipefail
# set -x   # uncomment for debugging

#
# ENV / CONSTANTS
#
export APP=clearnet
export APP_DATADIR=/mnt/hdd/mynode/${APP}
export MYNODE_CERTDIR=/home/bitcoin/.mynode/https
export LETSENCRYPT_HOME=/etc/letsencrypt
export LETSENCRYPT_DATADIR=$APP_DATADIR/letsencrypt
export LETSENCRYPT_BACKUPDIR=/mnt/hdd/mynode/${APP}_backup/letsencrypt

# Global runtime variables filled later
HTTPS_DOMAIN=""
HTTPS_BASE_CERT=""
PUBLIC_IP=""
declare -a DOMAINS=()
declare -a HTTPS_HOSTS=()
declare -A RESOLVE_CACHE=()

#
# UTILITIES
#
log() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
err() { printf "[ERROR] %s\n" "$*" >&2; exit 1; }

#
# RESTORE OR CREATE DEFAULT APP_DATADIR
#
# If a backup exists in /mnt/hdd/mynode/${APP}_backup find the newest *.tgz and restore its contents
# into APP_DATADIR. If no backup found, create APP_DATADIR and add default files:
# - https_domain (one line yourdomain.tld)
# - https_domain_contact (one line contact@yourdomain.tld)
# - https_hosts (commented template list per user request)
restore_or_create_app_datadir() {
    local backup_root="/mnt/hdd/mynode/${APP}_backup"
    log "Checking for existing backup in ${backup_root}"

    if [ -d "$backup_root" ]; then
        # find newest .tgz by modification time (most recent)
        # use find with -printf for portability on GNU find; fallback if not available
        local latest=""
        if command -v find >/dev/null 2>&1 ; then
            latest=$(find "$backup_root" -maxdepth 1 -type f -name '*.tgz' -printf '%T@ %p\n' 2>/dev/null | sort -k1,1nr | awk '{print $2}' | head -n1 || true)
        fi
        # fallback using ls if find with -printf isn't available
        if [ -z "$latest" ]; then
            latest=$(ls -1t "$backup_root"/*.tgz 2>/dev/null | head -n1 || true)
        fi

        if [ -n "$latest" ] && [ -f "$latest" ]; then
            log "Found backup archive: $latest"
            mkdir -p "$APP_DATADIR"
            # extract into APP_DATADIR; if tar contains top-level folder it will be created inside APP_DATADIR
            if tar -tzf "$latest" >/dev/null 2>&1; then
                log "Restoring backup archive into $APP_DATADIR"
                tar -xzf "$latest" -C "$APP_DATADIR" || err "Failed to extract backup $latest"
                log "Restoration completed from $latest"
                return 0
            else
                warn "Backup archive $latest appears invalid; continuing to create defaults"
            fi
        else
            log "No backup archive found in $backup_root"
        fi
    else
        log "Backup root $backup_root not present"
    fi

    # No usable backup found -> create APP_DATADIR and default files
    log "Creating ${APP_DATADIR} and default configuration files"

    mkdir -p "$APP_DATADIR"

    # https_domain
    if [ ! -f "$APP_DATADIR/https_domain" ]; then
        cat > "$APP_DATADIR/https_domain" <<'EOF'
yourdomain.tld
EOF
        log "Created $APP_DATADIR/https_domain (please edit to your real domain)"
    else
        log "$APP_DATADIR/https_domain already exists; leaving intact"
    fi

    # https_domain_contact
    if [ ! -f "$APP_DATADIR/https_domain_contact" ]; then
        cat > "$APP_DATADIR/https_domain_contact" <<'EOF'
contact@yourdomain.tld
EOF
        log "Created $APP_DATADIR/https_domain_contact (please edit to a valid contact email)"
    else
        log "$APP_DATADIR/https_domain_contact already exists; leaving intact"
    fi

    # hosts files: create https_hosts
    local hosts_content
    read -r -d '' hosts_content <<'EOF' || true
# Add hosts here one each line without #
# btcpay
# lnbits
# lndhub
# mempool
# pwallet
# phoenixd
EOF

    if [ ! -f "$APP_DATADIR/http_hosts" ]; then
        printf "%s\n" "$hosts_content" > "$APP_DATADIR/https_hosts"
        log "Created $APP_DATADIR/https_hosts (edit to add hosts)"
    else
        log "$APP_DATADIR/https_hosts already exists; leaving intact"
    fi

    return 0
}

#
# SETUP
#
setup_dirs_and_packages() {
    log "Creating working directories"
    mkdir -p "/opt/mynode/${APP}"
    mkdir -p "$MYNODE_CERTDIR"

    # install certbot and plugin if missing
    pkgs=(certbot python3-certbot python3-certbot-nginx curl)
    missing=()
    for p in "${pkgs[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        log "Installing missing packages: ${missing[*]}"
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        log "Required packages present"
    fi
}

prepare_letsencrypt_dir() {
    # If /etc/letsencrypt exists as directory, move to DATADIR and symlink (retain previous behaviour)
    if [ -L "$LETSENCRYPT_HOME" ]; then
        target=$(readlink -f "$LETSENCRYPT_HOME")
        if [ "$target" = "$LETSENCRYPT_DATADIR" ]; then
            log "$LETSENCRYPT_HOME already points to $LETSENCRYPT_DATADIR"
            return 0
        else
            err "$LETSENCRYPT_HOME is a symlink to $target, not $LETSENCRYPT_DATADIR. Aborting."
        fi
    elif [ -d "$LETSENCRYPT_HOME" ]; then
        ts=$(date +%Y%m%d-%H%M%S)
        backup_file="$LETSENCRYPT_BACKUPDIR/${APP}-letsencrypt-backup-$ts.tgz"
        mkdir -p "$LETSENCRYPT_BACKUPDIR"
        if [ ! -e "${LETSENCRYPT_BACKUPDIR}.org" ]; then
            cp -va "$LETSENCRYPT_HOME" "${LETSENCRYPT_BACKUPDIR}.org"
            log "Saved original letsencrypt to ${LETSENCRYPT_BACKUPDIR}.org"
        fi
        tar -czf "$backup_file" -C "$(dirname "$LETSENCRYPT_HOME")" "$(basename "$LETSENCRYPT_HOME")"
        log "Created backup archive $backup_file"
        if [ -e "$LETSENCRYPT_DATADIR" ]; then
            err "Destination $LETSENCRYPT_DATADIR already exists. Aborting to avoid nested move."
        fi
        mkdir -p "$(dirname "$LETSENCRYPT_DATADIR")"
        mv "$LETSENCRYPT_HOME" "$LETSENCRYPT_DATADIR"
        ln -s "$LETSENCRYPT_DATADIR" "$LETSENCRYPT_HOME"
        log "Replaced $LETSENCRYPT_HOME with symlink to $LETSENCRYPT_DATADIR"
    fi
}

#
# INPUTS
#
read_inputs() {
    HTTPS_DOMAIN=$( { cat "$APP_DATADIR/https_domain"; } 2>/dev/null ) || err "HTTPS_DOMAIN file missing at $APP_DATADIR/https_domain"
    HTTPS_DOMAIN=$(echo "$HTTPS_DOMAIN" | tr -d '[:space:]')
    if [ -z "$HTTPS_DOMAIN" ]; then
        err "HTTPS_DOMAIN empty in $APP_DATADIR/https_domain"
    fi
    HTTPS_BASE_CERT="$(hostname).${HTTPS_DOMAIN}"
    DOMAINS=("$HTTPS_BASE_CERT" "$HTTPS_DOMAIN")
    # read hosts file if present
    HTTPS_HOSTS_FILE="$APP_DATADIR/https_hosts"
    if [ -f "$HTTPS_HOSTS_FILE" ]; then
        log "Reading extra hostnames from $HTTPS_HOSTS_FILE"
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            line=$(printf "%s" "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            case "$line" in
                ""|\#*) continue ;;
            esac
            host="${line%%#*}"
            host=$(printf "%s" "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$host" ] && continue
            if ! echo "$host" | grep -q '\.'; then
                host="${host}.${HTTPS_DOMAIN}"
            fi
            DOMAINS+=("$host")
        done < "$HTTPS_HOSTS_FILE"
    else
        log "No $HTTPS_HOSTS_FILE file found; only using ${HTTPS_BASE_CERT} and ${HTTPS_DOMAIN}"
    fi
}

#
# DNS + PUBLIC IP helpers (cached)
#
resolve_host_ips() {
    # returns newline-separated IPs for given hostname; follows CNAME chain up to depth limit
    local host="$1"
    local depth=0
    local max_depth=6
    local target="$host"
    local tried=()
    while [ "$depth" -lt "$max_depth" ]; do
        depth=$((depth+1))
        local ips=()
        # First attempt: getent ahosts (works in many environments and returns resolved addresses)
        if command -v getent >/dev/null 2>&1; then
            while read -r ip _; do
                [ -n "$ip" ] && ips+=("$ip")
            done < <(getent ahosts "$target" 2>/dev/null | awk '{print $1 " " $2}' | uniq)
        fi
        # Next attempt: host command A/AAAA lines
        if [ "${#ips[@]}" -eq 0 ] && command -v host >/dev/null 2>&1; then
            # get A/AAAA records and also capture CNAME if present
            local host_out
            host_out=$(host "$target" 2>/dev/null || true)
            if [ -n "$host_out" ]; then
                while read -r line; do
                    # "name has address 1.2.3.4"
                    if echo "$line" | grep -q "has address"; then
                        ip=$(echo "$line" | awk '{print $4}')
                        [ -n "$ip" ] && ips+=("$ip")
                    fi
                done <<< "$host_out"
            fi
        fi

        # If we found IPs, return them (unique)
        if [ "${#ips[@]}" -gt 0 ]; then
            printf "%s\n" "${ips[@]}" | sort -u
            return 0
        fi

        # No IPs found yet: try to follow CNAME
        local cname=""
        # Try 'host -t CNAME' style or parse earlier host output
        if command -v host >/dev/null 2>&1; then
            cname=$(host -t CNAME "$target" 2>/dev/null || true)
            cname=$(printf "%s" "$cname" | awk -F' = ' '/canonical name =/ {print $2}' | sed 's/\.$//')
            if [ -z "$cname" ]; then
                cname=$(host "$target" 2>/dev/null | awk -F' = ' '/canonical name =/ {print $2}' | sed 's/\.$//')
            fi
        fi
        # if host didn't give cname, try dig
        if [ -z "$cname" ] && command -v dig >/dev/null 2>&1; then
            cname=$(dig +short CNAME "$target" 2>/dev/null || true)
            cname=$(printf "%s" "$cname" | sed 's/\.$//')
        fi

        if [ -n "$cname" ]; then
            # avoid loops
            for t in "${tried[@]}"; do
                if [ "$t" = "$cname" ]; then
                    break 2
                fi
            done
            tried+=("$target")
            target="$cname"
            # loop to resolve the cname target
            continue
        fi

        # No cname or IPs found: nothing more to do
        break
    done

    return 1
}

get_resolved_ips_cached() {
    local name="$1"
    if [ -n "${RESOLVE_CACHE[$name]+set}" ]; then
        IFS='|' read -r -a parts <<< "${RESOLVE_CACHE[$name]}"
        for p in "${parts[@]}"; do
            [ -n "$p" ] && printf "%s\n" "$p"
        done
        [ -n "${RESOLVE_CACHE[$name]}" ] && return 0 || return 1
    fi
    local out
    out=$(resolve_host_ips "$name" 2>/dev/null || true)
    if [ -n "$out" ]; then
        RESOLVE_CACHE[$name]="${out//$'\n'/'|'}"
        printf "%s\n" "$out"
        return 0
    fi
    RESOLVE_CACHE[$name]=""
    return 1
}

get_public_ip() {
    local services=( "https://ifconfig.co" "https://icanhazip.com" "https://ipinfo.io/ip" )
    local ips=()
    for s in "${services[@]}"; do
        ip=$(curl -s --max-time 6 "$s" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ]; then
            ips+=("$ip")
            log "public check $s -> $ip"
        else
            warn "public check $s returned empty"
        fi
    done
    # unique
    readarray -t unique_ips < <(printf "%s\n" "${ips[@]}" | sort -u)
    if [ "${#unique_ips[@]}" -eq 0 ]; then
        err "Could not determine public IP from any service"
    elif [ "${#unique_ips[@]}" -gt 1 ]; then
        err "UNCERTAIN-PUBLIC-IP: Services reported differing public IPs: ${unique_ips[*]}"
    else
        PUBLIC_IP="${unique_ips[0]}"
        log "Determined public IP: ${PUBLIC_IP}"
    fi
}

#
# Primary verification helpers
#
check_primary_domain() {
    local fqdn="$1"
    local resolved=()
    while IFS= read -r ip; do
        [ -n "$ip" ] && resolved+=("$ip")
    done < <(get_resolved_ips_cached "$fqdn" || true)

    if [ "${#resolved[@]}" -eq 0 ]; then
        warn "NON-RESOLVED-PRIMARY $fqdn"
        return 1
    fi
    log "RESOLVES-OK-PRIMARY $fqdn -> ${resolved[*]}"
    for ip in "${resolved[@]}"; do
        if [ "$ip" = "$PUBLIC_IP" ]; then
            log "PRIMARY-MATCH $fqdn -> ${PUBLIC_IP}"
            return 0
        fi
    done
    warn "PRIMARY-NO-MATCH $fqdn resolves to ${resolved[*]} which does not match public IP ${PUBLIC_IP}"
    return 2
}

#
# Contact email handling - MANDATORY: must exist, valid, and domain must have MX records.
#
check_mx_for_domain() {
    local domain="$1"
    if command -v host >/dev/null 2>&1; then
        out=$(host -t MX "$domain" 2>/dev/null || true)
        if [ -n "$out" ] && ! echo "$out" | grep -qi "has no MX record"; then
            return 0
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

get_and_validate_contact_email_or_exit() {
    local contact_file="$APP_DATADIR/https_domain_contact"
    if [ ! -f "$contact_file" ]; then
        err "Contact file $contact_file not found. Contact email is mandatory; aborting."
    fi
    CONTACT_EMAIL=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p}' "$contact_file" | tr -d '\r\n')
    if [ -z "$CONTACT_EMAIL" ]; then
        err "Contact file $contact_file is empty. Contact email is mandatory; aborting."
    fi
    # basic format check
    if ! echo "$CONTACT_EMAIL" | grep -Eq '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$'; then
        err "Contact email '$CONTACT_EMAIL' does not look valid. Aborting."
    fi
    CONTACT_DOMAIN="${CONTACT_EMAIL#*@}"
    if ! check_mx_for_domain "$CONTACT_DOMAIN"; then
        err "Contact email domain '$CONTACT_DOMAIN' has no MX records (or MX check tools unavailable). Aborting."
    fi
    log "Using contact email $CONTACT_EMAIL (MX ok for $CONTACT_DOMAIN)"
}

#
# Verify candidate domains, build HTTPS_HOSTS (only those resolving to PUBLIC_IP)
#
verify_and_filter_domains() {
    local candidates=("$@")
    HTTPS_HOSTS=()
    RESOLVE_CACHE=()  # reset per run

    get_public_ip

    # Primary names required
    if ! check_primary_domain "$HTTPS_BASE_CERT"; then
        err "Required primary name ${HTTPS_BASE_CERT} failed verification. Aborting."
    fi
    if ! check_primary_domain "$HTTPS_DOMAIN"; then
        err "Required primary name ${HTTPS_DOMAIN} failed verification. Aborting."
    fi

    declare -A seen=()
    for fqdn in "${candidates[@]}"; do
        if [ -n "${seen[$fqdn]+set}" ]; then
            log "SKIP-DUP $fqdn"
            continue
        fi
        seen[$fqdn]=1

        resolved_ips=()
        while IFS= read -r ip; do
            [ -n "$ip" ] && resolved_ips+=("$ip")
        done < <(get_resolved_ips_cached "$fqdn" || true)

        if [ "${#resolved_ips[@]}" -eq 0 ]; then
            warn "NON-RESOLVED $fqdn"
            continue
        fi
        log "RESOLVES-OK $fqdn -> ${resolved_ips[*]}"

        match=false
        for ip in "${resolved_ips[@]}"; do
            if [ "$ip" = "$PUBLIC_IP" ]; then
                match=true
                break
            fi
        done

        if [ "$match" = true ]; then
            log "MATCH $fqdn -> ${PUBLIC_IP}"
            HTTPS_HOSTS+=("$fqdn")
        else
            warn "IGNORED $fqdn resolves to ${resolved_ips[*]} which does not match public IP ${PUBLIC_IP}"
        fi
    done
}

#
# Single certbot invocation and symlink creation
#
obtain_and_link_cert() {
    local matched=("$@")
    if [ "${#matched[@]}" -eq 0 ]; then
        err "No matched domains to request certificates for. Aborting."
    fi

    # Ensure HTTPS_BASE_CERT is present among matched domains (it should be)
    local found_base=false
    for d in "${matched[@]}"; do
        if [ "$d" = "$HTTPS_BASE_CERT" ]; then
            found_base=true
            break
        fi
    done
    if ! $found_base; then
        err "${HTTPS_BASE_CERT} must be among matched domains but was not found. Aborting."
    fi

    # Build ordered unique list: base, domain, then other matched (de-duped)
    declare -A in_order=()
    ordered=()
    ordered+=("$HTTPS_BASE_CERT"); in_order["$HTTPS_BASE_CERT"]=1
    ordered+=("$HTTPS_DOMAIN"); in_order["$HTTPS_DOMAIN"]=1

    for d in "${matched[@]}"; do
        [ "${in_order[$d]+set}" ] && continue
        in_order["$d"]=1
        ordered+=("$d")
    done

    # prepare certbot args
    domain_args=()
    for d in "${ordered[@]}"; do
        domain_args+=("-d" "$d")
    done

    DRY_RUN_FLAG=()
    if [ -f "$APP_DATADIR/certbot_dry_run" ]; then
        DRY_RUN_FLAG+=(--dry-run)
        log "certbot will run in --dry-run mode due to $APP_DATADIR/certbot_dry_run"
    fi

    # contact email must have been validated already
    if [ -z "${CONTACT_EMAIL:-}" ]; then
        err "Internal error: CONTACT_EMAIL empty"
    fi

    primary_cert_name="$HTTPS_BASE_CERT"
    LE_CERT_PATH="$LETSENCRYPT_HOME/live/${primary_cert_name}"

    log "Running single certbot invocation (primary=${primary_cert_name}) for: ${ordered[*]}"
    certbot certonly --expand --nginx --non-interactive --agree-tos "${DRY_RUN_FLAG[@]}" -m "$CONTACT_EMAIL" --http-01-port 18080 "${domain_args[@]}" || err "certbot failed to obtain certificates"

    if [ ! -d "$LE_CERT_PATH" ] || [ ! -e "$LE_CERT_PATH/fullchain.pem" ] || [ ! -e "$LE_CERT_PATH/privkey.pem" ]; then
        err "certbot did not produce expected files at $LE_CERT_PATH"
    fi
    log "Successfully obtained certs for ${primary_cert_name} at $LE_CERT_PATH"

    # create symlinks using HTTPS_BASE_CERT primary name
    if [ -L "$MYNODE_CERTDIR/${primary_cert_name}.crt" ] || [ -e "$MYNODE_CERTDIR/${primary_cert_name}.crt" ]; then
        warn "${MYNODE_CERTDIR}/${primary_cert_name}.crt already exists; skipping"
    else
        ln -s "$LE_CERT_PATH/fullchain.pem" "$MYNODE_CERTDIR/${primary_cert_name}.crt"
        log "Created symlink ${MYNODE_CERTDIR}/${primary_cert_name}.crt -> $LE_CERT_PATH/fullchain.pem"
    fi
    if [ -L "$MYNODE_CERTDIR/${primary_cert_name}.key" ] || [ -e "$MYNODE_CERTDIR/${primary_cert_name}.key" ]; then
        warn "${MYNODE_CERTDIR}/${primary_cert_name}.key already exists; skipping"
    else
        ln -s "$LE_CERT_PATH/privkey.pem" "$MYNODE_CERTDIR/${primary_cert_name}.key"
        log "Created symlink ${MYNODE_CERTDIR}/${primary_cert_name}.key -> $LE_CERT_PATH/privkey.pem"
    fi
}

#
# MAIN
#
main() {
    # New: restore APP_DATADIR from latest backup if present, otherwise create default APP_DATADIR files.
    restore_or_create_app_datadir

    setup_dirs_and_packages
    prepare_letsencrypt_dir
    read_inputs

    # compact verification stage close after setup
    get_and_validate_contact_email_or_exit

    verify_and_filter_domains "${DOMAINS[@]}"

    # HTTPS_HOSTS should now contain all matched domains; ensure primary present
    if [ "${#HTTPS_HOSTS[@]}" -eq 0 ]; then
        err "No matched domains to request certificates for after verification. Exiting."
    fi

    obtain_and_link_cert "${HTTPS_HOSTS[@]}"

    log "Done."
}

main "$@"