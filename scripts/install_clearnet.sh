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
# Obtain certificates with certbot if not already present
# - Uses HTTP-01 on port 18080 as requested
# - Non-interactive, agree-to-tos and sets contact email to info@${HTTPS_DOMAIN}
#
LE_CERT_PATH="$LETSENCRYPT_HOME/live/${HTTPS_BASE_CERT}"

if [ -d "$LE_CERT_PATH" ] && [ -e "$LE_CERT_PATH/fullchain.pem" ] && [ -e "$LE_CERT_PATH/privkey.pem" ]; then
    echo "[SKIP] Certificate for ${HTTPS_BASE_CERT} already exists at $LE_CERT_PATH"
else
    echo "[INFO] Requesting certificates for ${HTTPS_BASE_CERT} and subdomains via certbot"

    # Build domain arguments
    DOMAINS=(
        "${HTTPS_BASE_CERT}"
        "${HTTPS_DOMAIN}"
        "lnbits.${HTTPS_DOMAIN}"
        "btcpay.${HTTPS_DOMAIN}"
        "lndhub.${HTTPS_DOMAIN}"
        "pwallet.${HTTPS_DOMAIN}"
        "phoenixd.${HTTPS_DOMAIN}"
    )

    domain_args=()
    for d in "${DOMAINS[@]}"; do
        domain_args+=("-d" "$d")
    done

    # Run certbot - adjust as needed if nginx needs special configuration beforehand.
    if ! certbot certonly --nginx --non-interactive --agree-tos -m "info@${HTTPS_DOMAIN}" --http-01-port 18080 "${domain_args[@]}"; then
        echo "[ERROR] certbot failed to obtain certificates for ${HTTPS_BASE_CERT}" >&2
        exit 1
    fi

    # Verify creation
    if [ -d "$LE_CERT_PATH" ] && [ -e "$LE_CERT_PATH/fullchain.pem" ] && [ -e "$LE_CERT_PATH/privkey.pem" ]; then
        echo "[INFO] Successfully obtained certs for ${HTTPS_BASE_CERT}"
    else
        echo "[ERROR] certbot did not produce expected files at $LE_CERT_PATH" >&2
        exit 1
    fi
fi

# Create symlinks for certs
if [ -L "$MYNODE_CERTDIR/${HTTPS_BASE_CERT}.crt" ] || [ -e "$MYNODE_CERTDIR/${HTTPS_BASE_CERT}.crt" ]; then
    echo "[ERROR] ${MYNODE_CERTDIR}/${HTTPS_BASE_CERT}.crt already exists. Aborting to avoid overwrite." >&2
    exit 1
else
    ln -s "$LETSENCRYPT_HOME/live/${HTTPS_BASE_CERT}/fullchain.pem" "$MYNODE_CERTDIR/${HTTPS_BASE_CERT}.crt"
    echo "[INFO] Created symlink for ${HTTPS_BASE_CERT}.crt"
fi

if [ -L "$MYNODE_CERTDIR/${HTTPS_BASE_CERT}.key" ] || [ -e "$MYNODE_CERTDIR/${HTTPS_BASE_CERT}.key" ]; then
    echo "[ERROR] ${MYNODE_CERTDIR}/${HTTPS_BASE_CERT}.key already exists. Aborting to avoid overwrite." >&2
    exit 1
else
    ln -s "$LETSENCRYPT_HOME/live/${HTTPS_BASE_CERT}/privkey.pem" "$MYNODE_CERTDIR/${HTTPS_BASE_CERT}.key"
    echo "[INFO] Created symlink for ${HTTPS_BASE_CERT}.key"
fi

echo "[INFO] =================== DONE INSTALLING APP ================="