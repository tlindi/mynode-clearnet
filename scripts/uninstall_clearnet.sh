#!/bin/bash

set -e
set -x

export APP=clearnet
export CLEARNET_DATADIR=/mnt/hdd/mynode/${APP}
export APP_BACKUPDIR=/mnt/hdd/mynode/${APP}_backup
export LETSENCRYPT_DATADIR=$CLEARNET_DATADIR/letsencrypt
export LETSENCRYPT_BACKUPDIR=$APP_BACKUPDIR/letsencrypt
export ORIGINAL_LETSENCRYPT="${LETSENCRYPT_BACKUPDIR}.org"
export MYNODE_CERTDIR=/home/bitcoin/.mynode/https

echo "[INFO] ==================== UNINSTALLING ${APP} ===================="

# Timestamp for backups
ts=$(date +%Y%m%d-%H%M%S)

# Ensure backup directories exist
mkdir -p "$LETSENCRYPT_BACKUPDIR"
mkdir -p "$APP_BACKUPDIR"

# Backup current /etc/letsencrypt state before removal
le_backup_file="$LETSENCRYPT_BACKUPDIR/${APP}-letsencrypt-uninstall-backup-$ts.tgz"
if [ -d /etc/letsencrypt ]; then
    tar -czf "$le_backup_file" -C /etc letsencrypt
    echo "[INFO] Backed up /etc/letsencrypt to $le_backup_file"
else
    echo "[INFO] SKIP: /etc/letsencrypt not found, no backup created"
fi

# Backup CLEARNET_DATADIR contents except letsencrypt into APP_BACKUPDIR
app_backup_file="$APP_BACKUPDIR/${APP}-data-uninstall-backup-$ts.tgz"
if [ -d "$CLEARNET_DATADIR" ]; then
    # Create a tarball of CLEARNET_DATADIR contents excluding the letsencrypt subdirectory (if present).
    # Use a subshell to change to the data dir so the tar archive contains the directory contents (not the full path).
    (
        cd "$CLEARNET_DATADIR"
        # If there are no files other than letsencrypt, create an empty tar (tar will fail), so check for files first.
        # Find files excluding the letsencrypt directory.
        files_found=$(find . -mindepth 1 -maxdepth 1 ! -name "letsencrypt" | read -r _ && echo "yes" || echo "no")
        if [ "$files_found" = "yes" ]; then
            tar -czf "$app_backup_file" --exclude='./letsencrypt' .
            echo "[INFO] Backed up $CLEARNET_DATADIR (excluding letsencrypt) to $app_backup_file"
        else
            echo "[INFO] SKIP: No files to back up in $CLEARNET_DATADIR other than letsencrypt"
        fi
    )
else
    echo "[INFO] SKIP: $CLEARNET_DATADIR not found, no data backup created"
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

# Remove certbot and related packages if installed (non-interactive, keep any existing conf files)
# Use DEBIAN_FRONTEND=noninteractive and force dpkg to keep old config files (--force-confold).
for pkg in certbot python3-certbot python3-certbot-nginx; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -o Dpkg::Options::="--force-confold" "$pkg" < /dev/null
        echo "[INFO] Removed package: $pkg"
    else
        echo "[INFO] SKIP: Package $pkg not installed"
    fi
done

echo "[INFO] =================== DONE UNINSTALLING ${APP} ================="