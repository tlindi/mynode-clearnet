from flask import Blueprint, render_template, redirect
from user_management import check_logged_in
from enable_disable_functions import *
from device_info import *
from application_info import *
from systemctl_info import *
import subprocess
import os


mynode_clearnet = Blueprint('mynode_clearnet',__name__)


### Page functions (have prefix /app/<app name/)
@mynode_clearnet.route("/info")
def clearnet_page():
    check_logged_in()

    app = get_application("clearnet")
    app_status = get_application_status("clearnet")
    app_status_color = get_application_status_color("clearnet")
###
#  1) create textboxes https_domain and contact email (eg info@<https_domain> setup and update
###
#  2) add button to Register SSL Certs
###
# sudo certbot certonly --nginx --agree-tos -m info@<https_domain> --http-01-port 18080 \
# -d <https_domain> -d node.<https_domain> -d lnbits.<https_domain> -d btcpay.<https_domain> -d lndhub.<https_domain> \
# -d pwallet.<https_domain> -d phoenixd.<https_domain>
## backup old and activate new MyNode https_public_apps cert and key
# sudo mv /home/bitcoin/.mynode/https/public_apps.crt /home/bitcoin/.mynode/https/public_apps.crt.org
# sudo mv /home/bitcoin/.mynode/https/public_apps.key /home/bitcoin/.mynode/https/public_apps.key.org
# sudo ln -s /etc/letsencrypt/live/node.<https_domain>/fullchain.pem /home/bitcoin/.mynode/https/public_apps.crt 
# sudo ln -s /etc/letsencrypt/live/node.<https_domain>/privkey.pem /home/bitcoin/.mynode/https/public_apps.key
##
# sudo service nginx restart
###
#  3) add button to revoke certs
###
#  4) add button to show log from /var/log/letsencrypt/letsencrypt.log
###

    # Load page
    templateData = {
        "title": "myNode - " + app["name"],
        "ui_settings": read_ui_settings(),
        "app_status": app_status,
        "app_status_color": app_status_color,
        "app": app
    }
    return render_template('/app/generic_app.html', **templateData)

