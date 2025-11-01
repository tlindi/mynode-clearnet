# Clearnet app for MyNode

Ment to help advanced users to gain what is described at "Advanced Resolutions" chapter of
[My Device has a Lightning Network Error](https://mynodebtc.github.io/troubleshooting/lightning-network-error.html).

Target is in addition to enable publishing Apps to Clearnet as described in 
[Easy switch Tor - clearnet for bundle nodes - BOLT.FUN.mhtml ](https://github.com/tlindi/mynode-clearnet/raw/main/app_data/Readme.s/Easy%20switch%20Tor%20-%20clearnet%20for%20bundle%20nodes%20-%20BOLT.FUN.mhtml) by [Darthcoin](https://darth-coin.github.io/)
(on above link download with Right-Click and Save Link As)

## ✅ Completed Implementation

### 🔧 Install Script (clearnet_install.sh)
- Defines dynamic environment variables for app, data, and backup paths
- Creates working directories and ensures safe permissions
- Installs required packages (certbot, python3-certbot, python3-certbot-nginx) only if missing
- Migrates /etc/letsencrypt to MyNode disk:
- Creates .org and timestamped .tgz backups
- Moves original directory and replaces with symlink
- Reads domain from https_domain file
- Creates symlinks for:
  node.<domain>.crt → fullchain.pem
  node.<domain>.key → privkey.pem
  Aborts if symlinks already exist

### 🧹 Uninstall Script (clearnet_uninstall.sh)
- Backs up current /etc/letsencrypt before removal
- Removes cert symlinks based on domain file
- Restores original /etc/letsencrypt from .org backup
- Deletes app directories (/opt/mynode/clearnet, $APP_DATADIR)
- Purges certbot-related packages if installed

### 🧾 Logging & Safety
- All actions logged with [INFO], [SKIP], or [ERROR]
- Aborts on unexpected conditions to prevent data loss
- Assumes root execution, avoids sudo

### 🧩 MyNode Community App by MyNode SDK (clearnet.json)
- App metadata defined for MyNode UI and SDK
- App tile and homepage visibility enabled
- Custom app page with instructions for:
- DNS setup
- Router configuration
- Certificate management
- UI button links to /app/clearnet/info
- App marked as uninstallable and reinstallable
- SDK version: 2, app type: custom

### 🧩 TODOs for Full Certbot Integration & UI
🔐 Certificate Automation
- [ ] Add certbot command to request initial certificate:
bash
certbot --nginx -d node.<domain> --non-interactive --agree-tos --email <admin_email>
- [ ] Validate domain resolution and port 80/443 accessibility
- [ ] Add renewal cron job or systemd timer
- [ ] Add renewal hook to refresh symlinks or reload services

### 🖥️ MyNode Community App UI
- [ ] Create clearnet.service for UI launch/status
- [ ] Build web UI to:
- [ ] Display current domain and cert status
- [ ] Trigger cert renewal manually
- [ ] Show logs and backup status

(*) source [bolt.fun](https://bolt.fun/story/easy-switch-tor-clearnet-for-bundle-nodes--155/))
