#!/bin/bash

set -e
set -x

export APP=clearnet
export CLEARNET_DATADIR=/mnt/hdd/mynode/${APP}
export LETSENCRYPT_DATADIR=$CLEARNET_DATADIR/letsencrypt
export LETSENCRYPT_BACKUPDIR=/mnt/hdd/mynode/${APP}_backup/letsencrypt
export ORIGINAL_LETSENCRYPT="${LETSENCRYPT_BACKUPDIR}.org"
export MYNODE_CERTDIR=/home/bitcoin/.mynode/https

echo "[INFO] ==================== UNINSTALLING ${APP} ===================="

# Backup current letsencrypt state before removal
ts=$(date +%Y%m%d-%H%M%S)
backup_file="$LETSENCRYPT_BACKUPDIR/${APP}-letsencrypt-uninstall-backup-$ts.tgz"
mkdir -p "$LETSENCRYPT_BACKUPDIR"
if [ -d /etc/letsencrypt ]; then
    tar -czf "$backup_file" -C /etc letsencrypt
    echo "[INFO] Backed up /etc/letsencrypt to $backup_file"
else
    echo "[INFO] SKIP: /etc/letsencrypt not found, no backup created"
fi

# Remove symlinks from MYNODE_CERTDIR
domain_file="$CLEARNET_DATADIR/https_domain"
if [ -f "$domain_file" ]; then
    domain=$(<"$domain_file")
    for ext in crt key; do
        cert_file="$MYNODE_CERTDIR/node.$domain.$ext"
        if [ -L "$cert_file" ]; then
            rm "$cert_file"
            echo "[INFO] Removed symlink $cert_file"
        else
            echo "[INFO] SKIP: $cert_file not a symlink"
        fi
    done
else
    echo "[INFO] SKIP: Domain file $domain_file not found"
fi

# Remove symlink or directory at /etc/letsencrypt
if [ -L /etc/letsencrypt ]; then
    rm /etc/letsencrypt
    echo "[INFO] Removed symlink /etc/letsencrypt"
elif [ -d /etc/letsencrypt ]; then
    echo "[ERROR] /etc/letsencrypt is a real directory. Aborting to avoid overwriting." >&2
    exit 1
else
    echo "[INFO] SKIP: /etc/letsencrypt not found"
fi

# Restore original letsencrypt directory
if [ -d "$ORIGINAL_LETSENCRYPT" ]; then
    cp -a "$ORIGINAL_LETSENCRYPT" /etc/letsencrypt
    echo "[INFO] Restored original letsencrypt from $ORIGINAL_LETSENCRYPT"
else
    echo "[ERROR] Original backup $ORIGINAL_LETSENCRYPT not found. Cannot restore." >&2
    exit 1
fi

# Remove clearnet install directories
for dir in /opt/mynode/clearnet "$CLEARNET_DATADIR"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "[INFO] Removed directory $dir"
    else
        echo "[INFO] SKIP: $dir not found"
    fi
done

# Remove certbot and related packages if installed
for pkg in certbot python3-certbot python3-certbot-nginx; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        apt purge -y "$pkg"
        echo "[INFO] Removed package: $pkg"
    else
        echo "[INFO] SKIP: Package $pkg not installed"
    fi
done

echo "[INFO] =================== DONE UNINSTALLING ${APP} ================="
