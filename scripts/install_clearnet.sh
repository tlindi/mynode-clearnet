#!/bin/bash

source /usr/share/mynode/mynode_device_info.sh
source /usr/share/mynode/mynode_app_versions.sh

set -x
set -e

echo "==================== INSTALLING APP ===================="

# The current directory is the app install folder and the app tarball from GitHub
# has already been downloaded and extracted. Any additional env variables specified
# in the JSON file are also present.

# TODO: Perform installation steps here

# Variables
export APP=clearnet
export CLEARNET_DATADIR=/mnt/hdd/mynode/clearnet
export LETSENCRYPT_HOME=/etc/letsencrypt
export LETSENCRYPT_DATADIR=$CLEARNET_DATADIR/letsencrypt
export LETSENCRYPT_BACKUPDIR=/mnt/hdd/mynode/clearnet_backup/letsencrypt

# Ensure target dirs exist with safe permissions
for d in "$LETSENCRYPT_DATADIR" "$LETSENCRYPT_BACKUPDIR"; do
    if ! sudo mkdir -p "$d"; then
        echo "ERROR: Failed to create $d" >&2
        exit 1
    fi
    sudo chmod 700 "$d"
done

# Handle existing LETSENCRYPT_HOME
if [ -L "$LETSENCRYPT_HOME" ]; then
    # Case 1 or 3: directory is symlink
    target=$(readlink -f "$LETSENCRYPT_HOME")
    if [ "$target" = "$LETSENCRYPT_DATADIR" ]; then
        echo "INFO: $LETSENCRYPT_HOME already points to $LETSENCRYPT_DATADIR, leaving as-is."
    else
        echo "ERROR: $LETSENCRYPT_HOME is a symlink to $target, not $LETSENCRYPT_DATADIR. Aborting." >&2
        exit 1
    fi

elif [ -d "$LETSENCRYPT_HOME" ]; then
    # Case 2 of 3: real directory, back it up
    ts=$(date +%Y%m%d-%H%M%S)
    backup_file="$LETSENCRYPT_BACKUPDIR/${APP}-letsencrypt-backup-$ts.tgz"
    if ! sudo tar -czf "$backup_file" -C "$(dirname "$LETSENCRYPT_HOME")" "$(basename "$LETSENCRYPT_HOME")"; then
        echo "ERROR: Failed to create tar archive $backup_file" >&2
        exit 1
    fi
    if ! sudo mv "$LETSENCRYPT_HOME" "$LETSENCRYPT_BACKUPDIR/${APP}-letsencrypt.orig.$ts"; then
        echo "ERROR: Failed to move existing $LETSENCRYPT_HOME" >&2
        exit 1
    fi
    # Create symlink after backup
    if ! sudo ln -sfn "$LETSENCRYPT_DATADIR" "$LETSENCRYPT_HOME"; then
        echo "ERROR: Failed to link $LETSENCRYPT_HOME to $LETSENCRYPT_DATADIR" >&2
        exit 1
    fi

else
    # Case: 3 of 3 doesn't exist at all, just create symlink
    if ! sudo ln -sfn "$LETSENCRYPT_DATADIR" "$LETSENCRYPT_HOME"; then
        echo "ERROR: Failed to link $LETSENCRYPT_HOME to $LETSENCRYPT_DATADIR" >&2
        exit 1
    fi
# End of LETSENCRYPT_HOME SETUP

# Install required packages
if ! sudo apt -y install certbot python3-certbot-nginx; then
    echo "ERROR: Failed to install certbot packages" >&2
    exit 1
fi

echo "================== DONE INSTALLING APP ================="
