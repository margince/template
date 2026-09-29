#!/bin/bash
# Boot-time provisioning for the app instance: margince-api + a natively
# installed valkey (no ElastiCache — see network.tf/secrets.tf). Runs once,
# at first boot (cloud-init), as root.
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

dnf install -y valkey postgresql15 awscli2 unzip tar gzip amazon-cloudwatch-agent
# postgresql15 (client only, psql) — this stack's README uses THIS instance,
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
set -euo pipefail
ENV_FILE=/.env
umask 077
: > "$ENV_FILE"
%{ for s in secrets ~}
_value=$(aws secretsmanager get-secret-value --secret-id '${s.secret_id}' --region "${aws_region}" --query SecretString --output text)
if [[ "$_value" == *$'\n'* || "$_value" == *$'\r'* ]]; then
  echo "secret ${s.secret_id} contains a newline or carriage return; refusing to write to $ENV_FILE" >&2
  exit 1
fi
echo "${s.env_name}=$_value" >> "$ENV_FILE"
%{ endfor ~}
chmod 600 "$ENV_FILE"
FETCH_SECRETS
chmod 700 /opt/margince/fetch-secrets.sh
/opt/margince/fetch-secrets.sh

# ---- valkey: local, network-reachable by the worker instance too -----------
# 127.0.0.1 alone isn't enough here — worker (a separate EC2 instance) needs
# this over the network, not loopback, so an AUTH token replaces the
# loopback-only trust a single-box design could have skipped (network.tf's
# sg-app only lets sg-worker's traffic reach 6379 at all).
REDIS_PW="$(grep '^MARGINCE_REDIS_PASSWORD=' /.env | cut -d= -f2-)"
mkdir -p /etc/valkey/valkey.conf.d
cat > /etc/valkey/valkey.conf.d/margince.conf <<EOF
bind 0.0.0.0 -::1
requirepass $REDIS_PW
EOF
systemctl enable --now valkey

# ---- Build-if-missing: api + migrate binaries -------------------------------
BINARY_KEY="binaries/app-${image_tag}.tar.gz"
if aws s3 cp "s3://${blobstore_bucket}/$BINARY_KEY" /tmp/app-artifact.tar.gz --region "${aws_region}"; then
  echo "api binaries for tag ${image_tag} already published, skipping build"
  tar -xzf /tmp/app-artifact.tar.gz -C /opt/margince/bin
  rm /tmp/app-artifact.tar.gz
else
  echo "api binaries for tag ${image_tag} not yet published, building from source"

  GO_VERSION=1.26.6
  curl -fsSL "https://go.dev/dl/go$${GO_VERSION}.linux-$${GOARCH}.tar.gz" -o /tmp/go.tar.gz
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
  export PATH=$PATH:/usr/local/go/bin

  mkdir -p /opt/margince/src
  aws s3 cp "s3://${blobstore_bucket}/${source_object_key}" /tmp/source.zip --region "${aws_region}"
  unzip -q /tmp/source.zip -d /opt/margince/src
  rm /tmp/source.zip

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
After=network-online.target valkey.service
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
