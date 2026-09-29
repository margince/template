#!/bin/bash
# First-boot provisioning of the Margince VM, started by cloud-init. Safe to
# run again (sudo margince-setup) after fixing whatever made it stop; every
# step checks what is already in place. Log: /var/log/margince-setup.log.
set -euo pipefail
exec > >(tee -a /var/log/margince-setup.log) 2>&1

# shellcheck source=/dev/null
. /etc/margince/deploy.env

DATA=/var/lib/margince
DONE=/var/lib/margince-setup.done
export DEBIAN_FRONTEND=noninteractive

log() { echo "margince-setup: $(date -u +%H:%M:%S) $*"; }

if [[ -f "$DONE" ]]; then
  log "already provisioned ($DONE exists)"
  exit 0
fi

# ---- Packages -------------------------------------------------------------------------
log "installing packages"
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl git gnupg jq xz-utils openssl nginx certbot postgresql-client

# Redis 7.2.15: the exact version inside the redis:7.2 image digest the
# standard stack runs and Margince develops against. Ubuntu 24.04 ships 7.0,
# so it comes from Redis's own signed apt repository, pinned.
REDIS_VERSION="7.2.15"
if [[ ! -f /usr/share/keyrings/redis-archive-keyring.gpg ]]; then
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
fi
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  >/etc/apt/sources.list.d/redis.list
cat >/etc/apt/preferences.d/redis <<EOF
Package: redis redis-server redis-tools
Pin: version 6:${REDIS_VERSION}-*
Pin-Priority: 1001
EOF
apt-get update -q
apt-get install -y -q --no-install-recommends redis-server redis-tools
KV_SVC=redis-server KV_CONF=/etc/redis/redis.conf KV_USER=redis
KV_VERSION=$(redis-server --version | sed -n 's/.* v=\([0-9][0-9.]*\).*/\1/p')
case "$KV_VERSION" in
  "$REDIS_VERSION") log "redis-server $KV_VERSION" ;;
  *)
    log "redis-server ${KV_VERSION:-unknown} installed; expected Redis $REDIS_VERSION (Margince requires 7.0-7.2)"
    exit 1
    ;;
esac

# ---- Data disk --------------------------------------------------------------------------
# Terraform attaches the disk after the VM exists, so it may appear a little
# after first boot.
log "waiting for the data disk"
disk=""
for _ in $(seq 1 120); do
  for link in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
    if [[ -e "$link" ]]; then disk="$(readlink -f "$link")"; break 2; fi
  done
  sleep 5
done
[[ -n "$disk" ]] || { log "data disk (LUN 0) not found"; exit 1; }

if ! blkid "$disk" >/dev/null 2>&1; then
  log "formatting $disk"
  mkfs.ext4 -q -L margince-data "$disk"
fi
uuid="$(blkid -s UUID -o value "$disk")"
mkdir -p "$DATA"
if ! grep -q "UUID=$uuid" /etc/fstab; then
  echo "UUID=$uuid $DATA ext4 defaults,nofail,discard 0 2" >>/etc/fstab
fi
mountpoint -q "$DATA" || mount "$DATA"

# ---- Service user and directories ---------------------------------------------------------
# A fixed uid/gid, so files on the data disk keep their owner when the VM is
# rebuilt.
getent group margince >/dev/null || groupadd --system --gid 10001 margince
id margince >/dev/null 2>&1 ||
  useradd --system --uid 10001 --gid margince --home-dir "$DATA" --no-create-home \
    --shell /usr/sbin/nologin margince

install -d -m 0755 "$DATA/build" "$DATA/cache" /opt/margince
install -d -m 0700 -o margince -g margince "$DATA/blobstore"
install -d -m 0750 -o margince -g margince "$DATA/app" "$DATA/app/config"
install -d -m 0700 -o margince -g margince "$DATA/app/secrets"
# The api entrypoint writes /app/secrets/admin-password; /app lives on the
# data disk so margince.yaml edits survive a VM rebuild.
[[ -L /app ]] || ln -s "$DATA/app" /app
install -d -m 0750 -g margince /etc/margince
install -d -m 0700 /etc/margince/tls
install -d -m 0755 /var/www/letsencrypt

# Certificates on the data disk too, so a rebuilt VM keeps them.
if [[ ! -L /etc/letsencrypt ]]; then
  install -d -m 0755 "$DATA/letsencrypt"
  if [[ -d /etc/letsencrypt ]]; then cp -an /etc/letsencrypt/. "$DATA/letsencrypt/"; fi
  rm -rf /etc/letsencrypt
  ln -s "$DATA/letsencrypt" /etc/letsencrypt
fi

# ---- Redis (loopback only) ------------------------------------------------------------------
log "configuring $KV_SVC"
install -d -m 0750 "$DATA/redis"
chown -R "$KV_USER:$KV_USER" "$DATA/redis"
if ! grep -q '^# margince$' "$KV_CONF"; then
  cat >>"$KV_CONF" <<EOF
# margince
bind 127.0.0.1 -::1
protected-mode yes
port 6379
dir $DATA/redis
appendonly yes
EOF
fi
install -d "/etc/systemd/system/$KV_SVC.service.d"
cat >"/etc/systemd/system/$KV_SVC.service.d/margince.conf" <<EOF
[Service]
ReadWritePaths=$DATA/redis
EOF
systemctl daemon-reload
systemctl enable "$KV_SVC"
systemctl restart "$KV_SVC"

# ---- nginx with a placeholder certificate ---------------------------------------------------
log "configuring nginx"
if [[ ! -e /etc/margince/tls/fullchain.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=$PUBLIC_HOST" \
    -keyout /etc/margince/tls/privkey.pem -out /etc/margince/tls/fullchain.pem 2>/dev/null
fi
install -m 0644 /etc/margince/nginx.conf /etc/nginx/nginx.conf
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
nginx -t
systemctl enable nginx
systemctl restart nginx

# The Azure DNS name resolves already, so this usually succeeds at first
# boot. A custom hostname needs its DNS record first (README.md).
log "requesting a certificate for $PUBLIC_HOST"
margince-enable-tls || log "TLS not enabled yet; run 'sudo margince-enable-tls' once DNS for $PUBLIC_HOST points at this VM"

# ---- Secrets, build, database --------------------------------------------------------------
# The Key Vault role assignment is created after the VM, so allow it time.
log "reading secrets from Key Vault $KEY_VAULT_NAME"
MARGINCE_FETCH_ATTEMPTS=60 margince-fetch-secrets

log "building Margince at $GIT_REF (takes a while)"
MARGINCE_BUILD_NO_RESTART=1 MARGINCE_BUILD_PREFER_DEPLOYED=1 margince-build "$GIT_REF"

log "bootstrapping the database"
margince-bootstrap-db

# ---- margince.yaml (first boot only; edits are kept) ------------------------------------------
CFG=/app/config/margince.yaml
if [[ ! -f "$CFG" ]]; then
  log "writing $CFG"
  src="$DATA/build/src/config/margince.example.yaml"
  sed -e "s|^  name: Demo Workspace\$|  name: $WORKSPACE_NAME|" \
    -e "s|^  base_currency: EUR\$|  base_currency: $WORKSPACE_BASE_CURRENCY|" \
    -e "s|^  base_language: en\$|  base_language: $WORKSPACE_BASE_LANGUAGE|" \
    -e "s|^  timezone: Europe/Berlin\$|  timezone: $WORKSPACE_TIMEZONE|" \
    -e "s|^  email: admin@demo.test\$|  email: $ADMIN_EMAIL|" \
    -e "s|^  display_name: Demo Admin\$|  display_name: $ADMIN_DISPLAY_NAME|" \
    -e "s|^  password_file: config/margince-admin-password\$|  password_file: secrets/admin-password|" \
    "$src" >"$CFG.tmp"
  for want in "  name: $WORKSPACE_NAME" "  base_currency: $WORKSPACE_BASE_CURRENCY" \
    "  base_language: $WORKSPACE_BASE_LANGUAGE" "  timezone: $WORKSPACE_TIMEZONE" \
    "  email: $ADMIN_EMAIL" "  display_name: $ADMIN_DISPLAY_NAME" "  password_file: secrets/admin-password"; do
    if ! grep -qxF "$want" "$CFG.tmp"; then
      log "config/margince.example.yaml has changed shape; could not set '$want'. Edit $CFG.tmp by hand, move it to $CFG and run margince-setup again."
      exit 1
    fi
  done
  chown margince:margince "$CFG.tmp"
  chmod 0640 "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
fi

# ---- Services ------------------------------------------------------------------------------
log "starting margince-api and margince-worker"
systemctl daemon-reload
systemctl enable margince-api margince-worker
systemctl restart margince-api
systemctl restart margince-worker
systemctl reload nginx

touch "$DONE"
log "done. Margince: $PUBLIC_BASE_URL"
