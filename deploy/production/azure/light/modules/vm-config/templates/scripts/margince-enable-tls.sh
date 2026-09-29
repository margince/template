#!/bin/bash
# Gets a Let's Encrypt certificate for the public hostname and switches nginx
# from the self-signed placeholder to it. Run it once DNS for the hostname
# points at this VM's public IP:
#
#   sudo margince-enable-tls            # the hostname Terraform configured
#   sudo margince-enable-tls HOSTNAME   # another name served by this VM
#
# The certbot package's timer renews the certificate; the deploy hook reloads
# nginx after each renewal.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/margince/deploy.env

HOST="${1:-$PUBLIC_HOST}"
TLS_DIR=/etc/margince/tls
WEBROOT=/var/www/letsencrypt

public_ip="$(curl -fsS --max-time 5 -H Metadata:true \
  "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" || true)"
resolved="$(getent ahostsv4 "$HOST" | awk 'NR == 1 { print $1 }' || true)"

if [[ -z "$resolved" ]]; then
  echo "margince-enable-tls: $HOST does not resolve yet. Create an A record for it pointing at ${public_ip:-the public IP of this VM}, then run this again." >&2
  exit 1
fi
if [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
  echo "margince-enable-tls: $HOST resolves to $resolved, not to this VM ($public_ip). Fix the DNS record (or wait for it to propagate), then run this again." >&2
  exit 1
fi

email_args=(--register-unsafely-without-email)
if [[ -n "${ACME_EMAIL:-}" ]]; then
  email_args=(--email "$ACME_EMAIL")
fi

mkdir -p "$WEBROOT"
certbot certonly --webroot -w "$WEBROOT" -d "$HOST" \
  --non-interactive --agree-tos "${email_args[@]}" \
  --keep-until-expiring --deploy-hook "systemctl reload nginx"

ln -sfn "/etc/letsencrypt/live/$HOST/fullchain.pem" "$TLS_DIR/fullchain.pem"
ln -sfn "/etc/letsencrypt/live/$HOST/privkey.pem" "$TLS_DIR/privkey.pem"

nginx -t
systemctl reload nginx
echo "margince-enable-tls: https://$HOST now uses the Let's Encrypt certificate"
