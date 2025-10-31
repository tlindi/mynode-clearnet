#!/bin/bash

source /usr/share/mynode/mynode_device_info.sh
source /usr/share/mynode/mynode_app_versions.sh

echo "==================== UNINSTALLING APP ===================="

# The app folder will be removed automatically after this script runs. You may not need to do anything here.

# TODO: Perform special uninstallation steps here
sudo apt -y remove certbot
sudo apt -y remove python3-certbot-nginx

#
# Restore from backup old and activate new MyNode https_public_apps cert and key
#This is how new were made
# sudo mv /home/bitcoin/.mynode/https/public_apps.crt /home/bitcoin/.mynode/https/public_apps.crt.org
# sudo mv /home/bitcoin/.mynode/https/public_apps.key /home/bitcoin/.mynode/https/public_apps.key.org
# sudo ln -s /etc/letsencrypt/live/node.<https_domain>/fullchain.pem /home/bitcoin/.mynode/https/public_apps.crt 
# sudo ln -s /etc/letsencrypt/live/node.<https_domain>/privkey.pem /home/bitcoin/.mynode/https/public_apps.key

#

echo "================== DONE UNINSTALLING APP ================="
