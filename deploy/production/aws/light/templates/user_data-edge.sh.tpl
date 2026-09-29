#!/bin/bash
# Boot-time provisioning for the edge instance: nginx (reverse proxy + the
# built frontend). Runs once, at first boot (cloud-init), as root.
# Source archive sha: ${source_sha}
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

dnf install -y nginx amazon-cloudwatch-agent unzip tar gzip
systemctl enable nginx

mkdir -p /opt/margince/frontend/dist
chmod 755 /opt/margince

# ---- nginx config (routing + static serving, rendered by ec2.tf) ----------
base64 -d > /etc/nginx/conf.d/margince.conf <<'NGINX_CONF_B64'
${nginx_conf_b64}
NGINX_CONF_B64
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# ---- CloudWatch Agent: ships nginx's own logs to CloudWatch -----------------
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/nginx/access.log", "log_group_name": "${log_group}", "log_stream_name": "access" },
          { "file_path": "/var/log/nginx/error.log",  "log_group_name": "${log_group}", "log_stream_name": "error" }
        ]
      }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# ---- Build-if-missing: this tag's built frontend, from the S3 artifact
# cache (iam.tf's ReadWriteOwnBinaryCache), or from source if this is the
# first boot to ask for this tag ----------------------------------------------
# Keyed by tag AND source hash (build.tf), so never reused across source changes.
BINARY_KEY="${binary_key}"
if aws s3 cp "s3://${blobstore_bucket}/$BINARY_KEY" /tmp/edge-artifact.tar.gz --region "${aws_region}"; then
  echo "frontend for tag ${image_tag} (source ${source_sha}) already published, skipping build"
  tar -xzf /tmp/edge-artifact.tar.gz -C /opt/margince/frontend/dist
  rm /tmp/edge-artifact.tar.gz
else
  echo "frontend for tag ${image_tag} (source ${source_sha}) not yet published, building from source"

  mkdir -p /opt/margince/src
  aws s3 cp "s3://${blobstore_bucket}/${source_object_key}" /tmp/source.zip --region "${aws_region}"
  unzip -q /tmp/source.zip -d /opt/margince/src
  rm /tmp/source.zip

  # Go: only to run the composition codegen step below (gen-composition).
  # AL2023's dnf golang is older than go.work's pin, so the official tarball
  # at exactly that version, checksum-verified.
  GO_VERSION="$(awk '$1 == "go" { print $2; exit }' /opt/margince/src/go.work)"
  GO_TGZ="go$${GO_VERSION}.linux-$${GOARCH}.tar.gz"
  curl -fsSL "https://dl.google.com/go/$GO_TGZ" -o "/tmp/$GO_TGZ"
  echo "$(curl -fsSL "https://dl.google.com/go/$GO_TGZ.sha256")  /tmp/$GO_TGZ" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$GO_TGZ"
  rm -f "/tmp/$GO_TGZ"
  export PATH=$PATH:/usr/local/go/bin

  # Node: the major of the Dockerfile's node base image (AL2023's dnf nodejs
  # is older), latest patch of that major, checked against SHASUMS256.txt.
  NODE_MAJOR="$(sed -nE 's/^FROM .*node:([0-9]+).*/\1/p' /opt/margince/src/Dockerfile | head -n1)"
  NODE_MAJOR="$${NODE_MAJOR:-24}"
  NODE_ARCH="$([ "$GOARCH" = "arm64" ] && echo arm64 || echo x64)"
  NODE_BASE="https://nodejs.org/dist/latest-v$${NODE_MAJOR}.x"
  NODE_SUMS="$(curl -fsSL "$NODE_BASE/SHASUMS256.txt")"
  NODE_FILE="$(awk -v want="linux-$NODE_ARCH.tar.xz" 'substr($2, length($2) - length(want) + 1) == want { print $2; exit }' <<<"$NODE_SUMS")"
  curl -fsSL "$NODE_BASE/$NODE_FILE" -o "/tmp/$NODE_FILE"
  (cd /tmp && grep " $NODE_FILE\$" <<<"$NODE_SUMS" | sha256sum -c -)
  rm -rf /usr/local/node
  mkdir -p /usr/local/node
  tar -C /usr/local/node --strip-components=1 -xJf "/tmp/$NODE_FILE"
  rm -f "/tmp/$NODE_FILE"
  export PATH=/usr/local/node/bin:$PATH
  corepack enable

  # gen-composition materializes build/composition/frontend/, which the
  # frontend build below consumes — must run before it, and needs the
  # whole repo (relative paths into ../backend, ../extensions/*).
  (cd /opt/margince/src/backend && GOWORK=/opt/margince/src/go.work go run ./tools/gen-composition)

  cd /opt/margince/src
  corepack prepare "$(node -p "require('./package.json').packageManager")" --activate
  pnpm install --frozen-lockfile --prefer-offline --ignore-scripts
  (cd build/composition-frontend/workspace && pnpm install --no-frozen-lockfile --prefer-offline --ignore-scripts)

  cd frontend
  export MARGINCE_COMPOSITION_FRONTEND=/opt/margince/src/build/composition/frontend
  export MARGINCE_RELEASE_VERSION="${image_tag}"
  pnpm gen:composed-types
  pnpm gen:events:composed
  pnpm build:composed

  cp -r dist/. /opt/margince/frontend/dist/

  # Best-effort: publish for the next boot/instance to skip this build.
  tar -czf /tmp/edge-artifact.tar.gz -C /opt/margince/frontend/dist .
  aws s3 cp /tmp/edge-artifact.tar.gz "s3://${blobstore_bucket}/$BINARY_KEY" --region "${aws_region}" || true
  rm -f /tmp/edge-artifact.tar.gz
fi

systemctl restart nginx
