#!/bin/bash
# Boot-time provisioning for the worker instance: margince-worker only — no
# ingress from anywhere (network.tf), connects out to the app instance's
# valkey and to RDS. Runs once, at first boot (cloud-init), as root.
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

dnf install -y postgresql15 awscli2 unzip tar gzip amazon-cloudwatch-agent
# postgresql15 (client only) — worker itself runs no migrations, but the
# same CA bundle below is what its DSN's sslrootcert points at.

mkdir -p /app/config /opt/margince/bin

# ---- Config object + RDS CA bundle ------------------------------------------
aws s3 cp "s3://${blobstore_bucket}/config/margince.yaml" /app/config/margince.yaml --region "${aws_region}"
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o /app/config/rds-ca-bundle.pem

# ---- Secrets -> .env ---------------------------------------------------------
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

# ---- Build-if-missing: worker binary -----------------------------------------
BINARY_KEY="binaries/worker-${image_tag}.tar.gz"
if aws s3 cp "s3://${blobstore_bucket}/$BINARY_KEY" /tmp/worker-artifact.tar.gz --region "${aws_region}"; then
  echo "worker binary for tag ${image_tag} already published, skipping build"
  tar -xzf /tmp/worker-artifact.tar.gz -C /opt/margince/bin
  rm /tmp/worker-artifact.tar.gz
else
  echo "worker binary for tag ${image_tag} not yet published, building from source"

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
    -o /opt/margince/bin/margince-worker ./cmd/worker

  tar -czf /tmp/worker-artifact.tar.gz -C /opt/margince/bin margince-worker
  aws s3 cp /tmp/worker-artifact.tar.gz "s3://${blobstore_bucket}/$BINARY_KEY" --region "${aws_region}" || true
  rm -f /tmp/worker-artifact.tar.gz
fi
chmod +x /opt/margince/bin/margince-worker

# ---- worker-entrypoint.sh, unchanged from the repo — sources /.env, requires
# MARGINCE_DSN, execs margince-worker. -----------------------------------------
if [ -f /opt/margince/src/scripts/deploy/worker-entrypoint.sh ]; then
  cp /opt/margince/src/scripts/deploy/worker-entrypoint.sh /opt/margince/bin/worker-entrypoint.sh
else
  aws s3 cp "s3://${blobstore_bucket}/${source_object_key}" /tmp/source.zip --region "${aws_region}"
  unzip -q -o /tmp/source.zip scripts/deploy/worker-entrypoint.sh -d /tmp/src-extract
  cp /tmp/src-extract/scripts/deploy/worker-entrypoint.sh /opt/margince/bin/worker-entrypoint.sh
  rm -rf /tmp/source.zip /tmp/src-extract
fi
chmod +x /opt/margince/bin/worker-entrypoint.sh
sed -i 's#margince-worker#/opt/margince/bin/margince-worker#' /opt/margince/bin/worker-entrypoint.sh

# ---- systemd unit -----------------------------------------------------------
cat > /etc/systemd/system/margince-worker.service <<UNIT
[Unit]
Description=Margince worker
After=network-online.target
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
Environment=MARGINCE_BLOBSTORE_REGION=${aws_region}
Environment=MARGINCE_BLOBSTORE_USE_SSL=true
Environment=MARGINCE_LOG_FORMAT=json
Environment=MARGINCE_OBSERVE_ADDR=0.0.0.0:9101
ExecStartPre=/opt/margince/fetch-secrets.sh
ExecStart=/opt/margince/bin/worker-entrypoint.sh
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
          { "file_path": "/var/log/messages", "log_group_name": "${log_group}", "log_stream_name": "worker" }
        ]
      }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl daemon-reload
systemctl enable --now margince-worker.service
