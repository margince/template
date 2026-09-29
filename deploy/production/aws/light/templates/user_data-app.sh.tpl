#!/bin/bash
# Boot-time provisioning for the app instance: margince-api + redis in a
# Docker container (no ElastiCache — see network.tf/secrets.tf). Runs once,
# at first boot (cloud-init), as root. Source archive sha: ${source_sha}
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

dnf install -y docker postgresql16 awscli2 unzip tar gzip amazon-cloudwatch-agent
systemctl enable --now docker
# postgresql16 (client only, psql; same major as RDS) — this stack's README uses THIS instance,
# over SSM, to run scripts/deploy/db-bootstrap.sql against RDS once, since
# there's no separate bastion.

mkdir -p /app/config /app/secrets /opt/margince/bin
chmod 700 /app/secrets

# ---- Config object + RDS CA bundle ------------------------------------------
aws s3 cp "s3://${blobstore_bucket}/config/margince.yaml" /app/config/margince.yaml --region "${aws_region}"
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o /app/config/rds-ca-bundle.pem

# ---- Secrets -> .env (mode 600, never written to a log or S3) ---------------
cat > /opt/margince/fetch-secrets.sh <<'FETCH_SECRETS'
#!/bin/bash
# SSM Parameter Store SecureStrings (alias/aws/ssm), decrypted on read.
# Retries cover the instance profile / SSM endpoint not being ready yet
# right after boot, and SSM API throttling.
set -euo pipefail
ENV_FILE=/.env
TMP_FILE=/.env.tmp
umask 077

fetch_param() {
  local name="$1" value attempt
  for attempt in 1 2 3 4 5 6; do
    if value=$(aws ssm get-parameter --name "$name" --with-decryption --region "${aws_region}" --query Parameter.Value --output text); then
      printf '%s' "$value"
      return 0
    fi
    echo "reading SSM parameter $name failed (attempt $attempt), retrying" >&2
    sleep $((attempt * 5))
  done
  echo "giving up on SSM parameter $name" >&2
  return 1
}

: > "$TMP_FILE"
%{ for s in secrets ~}
_value=$(fetch_param '${s.parameter_name}')
if [[ "$_value" == *$'\n'* || "$_value" == *$'\r'* ]]; then
  echo "parameter ${s.parameter_name} contains a newline or carriage return; refusing to write to $ENV_FILE" >&2
  exit 1
fi
echo "${s.env_name}=$_value" >> "$TMP_FILE"
%{ endfor ~}
%{ if !license_set ~}
# No license token set (secrets.tf creates no parameter for an empty value).
echo "MARGINCE_LICENSE=" >> "$TMP_FILE"
%{ endif ~}
chmod 600 "$TMP_FILE"
# Atomic swap: a failed fetch never leaves a truncated /.env behind.
mv -f "$TMP_FILE" "$ENV_FILE"
FETCH_SECRETS
chmod 700 /opt/margince/fetch-secrets.sh
/opt/margince/fetch-secrets.sh

# ---- redis: Docker container, reachable by the worker instance too ---------
# 127.0.0.1 alone isn't enough here — worker (a separate EC2 instance) needs
# this over the network, not loopback, so an AUTH token replaces the
# loopback-only trust a single-box design could have skipped (network.tf's
# sg-app only lets sg-worker's traffic reach 6379 at all). The password sits
# in a mode-600 config file mounted into the container, never on a command
# line. AOF persistence on the host: /var/lib/margince/redis -> /data.
REDIS_PW="$(grep '^MARGINCE_REDIS_PASSWORD=' /.env | cut -d= -f2-)"
mkdir -p /etc/margince /var/lib/margince/redis
( umask 077; cat > /etc/margince/redis.conf <<EOF
bind 0.0.0.0
requirepass $REDIS_PW
appendonly yes
dir /data
EOF
)
# The official image runs redis-server as uid/gid 999.
chown 999:999 /etc/margince/redis.conf /var/lib/margince/redis
docker pull '${redis_image}'
cat > /etc/systemd/system/margince-redis.service <<'UNIT'
[Unit]
Description=Margince redis (Docker)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
ExecStartPre=-/usr/bin/docker rm -f margince-redis
ExecStart=/usr/bin/docker run --rm --name margince-redis -p 6379:6379 -v /var/lib/margince/redis:/data -v /etc/margince/redis.conf:/usr/local/etc/redis/redis.conf:ro ${redis_image} redis-server /usr/local/etc/redis/redis.conf
ExecStop=/usr/bin/docker stop margince-redis
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now margince-redis.service

# ---- Build-if-missing: api + migrate binaries -------------------------------
# Keyed by tag AND source hash (build.tf), so never reused across source changes.
BINARY_KEY="${binary_key}"
if aws s3 cp "s3://${blobstore_bucket}/$BINARY_KEY" /tmp/app-artifact.tar.gz --region "${aws_region}"; then
  echo "api binaries for tag ${image_tag} (source ${source_sha}) already published, skipping build"
  tar -xzf /tmp/app-artifact.tar.gz -C /opt/margince/bin
  rm /tmp/app-artifact.tar.gz
else
  echo "api binaries for tag ${image_tag} (source ${source_sha}) not yet published, building from source"

  mkdir -p /opt/margince/src
  aws s3 cp "s3://${blobstore_bucket}/${source_object_key}" /tmp/source.zip --region "${aws_region}"
  unzip -q /tmp/source.zip -d /opt/margince/src
  rm /tmp/source.zip

  # Go at the version the source's go.work pins, checksum-verified.
  GO_VERSION="$(awk '$1 == "go" { print $2; exit }' /opt/margince/src/go.work)"
  GO_TGZ="go$${GO_VERSION}.linux-$${GOARCH}.tar.gz"
  curl -fsSL "https://dl.google.com/go/$GO_TGZ" -o "/tmp/$GO_TGZ"
  echo "$(curl -fsSL "https://dl.google.com/go/$GO_TGZ.sha256")  /tmp/$GO_TGZ" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$GO_TGZ"
  rm -f "/tmp/$GO_TGZ"
  export PATH=$PATH:/usr/local/go/bin

  (cd /opt/margince/src/backend && GOWORK=/opt/margince/src/go.work go run ./tools/gen-composition)

  cd /opt/margince/src/backend
  GOWORK=/opt/margince/src/build/composition/go.work CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH \
    go build -ldflags="-s -w -X github.com/margince/margince/backend/internal/shared/buildinfo.ReleaseVersion=${image_tag}" \
    -o /opt/margince/bin/margince-api ./cmd/api
  GOWORK=/opt/margince/src/build/composition/go.work CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH \
    go build -ldflags="-s -w" -o /opt/margince/bin/margince-migrate ./cmd/migrate

  tar -czf /tmp/app-artifact.tar.gz -C /opt/margince/bin margince-api margince-migrate
  aws s3 cp /tmp/app-artifact.tar.gz "s3://${blobstore_bucket}/$BINARY_KEY" --region "${aws_region}" || true
  rm -f /tmp/app-artifact.tar.gz
fi
chmod +x /opt/margince/bin/margince-api /opt/margince/bin/margince-migrate

# ---- api-entrypoint.sh, unchanged from the repo — migrations + admin-
# password bootstrap, then exec margince-api. Fetched from the same source
# archive rather than duplicated here. ---------------------------------------
if [ -f /opt/margince/src/scripts/deploy/api-entrypoint.sh ]; then
  cp /opt/margince/src/scripts/deploy/api-entrypoint.sh /opt/margince/bin/api-entrypoint.sh
else
  # Build-if-missing's fast path never unpacked the source tree — fetch just
  # this one file rather than the whole archive again.
  aws s3 cp "s3://${blobstore_bucket}/${source_object_key}" /tmp/source.zip --region "${aws_region}"
  unzip -q -o /tmp/source.zip scripts/deploy/api-entrypoint.sh -d /tmp/src-extract
  cp /tmp/src-extract/scripts/deploy/api-entrypoint.sh /opt/margince/bin/api-entrypoint.sh
  rm -rf /tmp/source.zip /tmp/src-extract
fi
chmod +x /opt/margince/bin/api-entrypoint.sh
sed -i 's#margince-api#/opt/margince/bin/margince-api#; s#margince-migrate#/opt/margince/bin/margince-migrate#' /opt/margince/bin/api-entrypoint.sh

# ---- systemd unit -----------------------------------------------------------
cat > /etc/systemd/system/margince-api.service <<UNIT
[Unit]
Description=Margince api
After=network-online.target margince-redis.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/app
EnvironmentFile=/.env
Environment=MARGINCE_CONFIG=/app/config/margince.yaml
Environment=MARGINCE_REDIS=${redis_host}:6379
Environment=MARGINCE_REDIS_TLS=false
Environment=MARGINCE_PUBLIC_BASE_URL=${public_base_url}
Environment=MARGINCE_BLOBSTORE_ENDPOINT=s3.${aws_region}.amazonaws.com
Environment=MARGINCE_BLOBSTORE_BUCKET=${blobstore_bucket}
Environment=MARGINCE_BLOBSTORE_REGION=${aws_region}
Environment=MARGINCE_BLOBSTORE_USE_SSL=true
Environment=MARGINCE_LOG_FORMAT=json
ExecStartPre=/opt/margince/fetch-secrets.sh
ExecStart=/opt/margince/bin/api-entrypoint.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/messages", "log_group_name": "${log_group}", "log_stream_name": "api" }
        ]
      }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl daemon-reload
systemctl enable --now margince-api.service
