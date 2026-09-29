#!/bin/bash
# Builds Margince from source on this VM, the way the repository's Dockerfile
# does, and installs the result as a new release:
#
#   /opt/margince/releases/<commit>/bin        margince-migrate, margince-worker,
#                                              entrypoints, margince-api wrapper
#   /opt/margince/releases/<commit>/libexec    margince-api
#   /opt/margince/releases/<commit>/frontend   the composed SPA build
#   /opt/margince/current -> releases/<commit>
#
# Usage: sudo margince-build [git-ref]   (default: the ref Terraform set)
#
# When the services are already installed it restarts them; margince-api
# applies migrations at start. Source and caches live on the data disk.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/margince/deploy.env

REF="${1:-$GIT_REF}"
DATA=/var/lib/margince
SRC="$DATA/build/src"
CACHE="$DATA/cache"
RELEASES=/opt/margince/releases

export HOME="${HOME:-/root}"
export GOCACHE="$CACHE/go-build" GOMODCACHE="$CACHE/go-mod" GOTOOLCHAIN=local
export COREPACK_HOME="$CACHE/corepack" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export CI=true
export PATH="/usr/local/go/bin:/usr/local/node/bin:$PATH"
PNPM_STORE="$CACHE/pnpm-store"

case "$(uname -m)" in
  x86_64) GOARCH=amd64 NODEARCH=x64 ;;
  aarch64) GOARCH=arm64 NODEARCH=arm64 ;;
  *) echo "margince-build: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

log() { echo "margince-build: $*"; }

# ---- Source ---------------------------------------------------------------------
mkdir -p "$DATA/build" "$CACHE"
if [[ ! -d "$SRC/.git" ]]; then
  log "cloning $GIT_URL"
  git clone --filter=blob:none "$GIT_URL" "$SRC"
fi
cd "$SRC"
git remote set-url origin "$GIT_URL"
log "fetching $REF"
git fetch --force --tags origin "$REF"
git checkout --force --detach FETCH_HEAD
git clean -ffdx -e node_modules
SHA="$(git rev-parse HEAD)"
REL="$(git rev-parse --short=12 HEAD)"
log "building $REL ($SHA)"

# ---- Toolchains, at the versions the repository pins -----------------------------
GO_VERSION="$(awk '$1 == "go" { print $2; exit }' go.work)"
if [[ "$(go env GOVERSION 2>/dev/null || true)" != "go$GO_VERSION" ]]; then
  log "installing Go $GO_VERSION"
  tgz="go$GO_VERSION.linux-$GOARCH.tar.gz"
  curl -fsSL -o "/tmp/$tgz" "https://dl.google.com/go/$tgz"
  echo "$(curl -fsSL "https://dl.google.com/go/$tgz.sha256")  /tmp/$tgz" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$tgz"
  rm -f "/tmp/$tgz"
fi

# Node: the major version of the Dockerfile's node base image, latest patch.
NODE_MAJOR="$(sed -nE 's/^FROM .*node:([0-9]+).*/\1/p' Dockerfile | head -n1)"
NODE_MAJOR="${NODE_MAJOR:-24}"
if [[ "$(node -v 2>/dev/null | cut -d. -f1)" != "v$NODE_MAJOR" ]]; then
  log "installing Node $NODE_MAJOR"
  base="https://nodejs.org/dist/latest-v$NODE_MAJOR.x"
  sums="$(curl -fsSL "$base/SHASUMS256.txt")"
  file="$(awk -v want="linux-$NODEARCH.tar.xz" 'index($2, want) && substr($2, length($2) - length(want) + 1) == want { print $2 }' <<<"$sums")"
  curl -fsSL -o "/tmp/$file" "$base/$file"
  (cd /tmp && grep " $file\$" <<<"$sums" | sha256sum -c -)
  rm -rf /usr/local/node
  mkdir -p /usr/local/node
  tar -C /usr/local/node --strip-components=1 -xJf "/tmp/$file"
  rm -f "/tmp/$file"
fi

# ---- Go binaries (composed workspace) ---------------------------------------------
OUT="$(mktemp -d "$DATA/build/out.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/libexec" "$OUT/frontend"

(cd backend && GOWORK="$SRC/go.work" go run ./tools/gen-composition)

BI=github.com/margince/margince/backend/internal/shared/buildinfo
(
  cd backend
  export GOWORK="$SRC/build/composition/go.work" CGO_ENABLED=0 GOOS=linux GOARCH
  go build -ldflags="-s -w -X $BI.Revision=$SHA -X $BI.ReleaseVersion=$REL" -o "$OUT/libexec/margince-api" ./cmd/api
  go build -ldflags="-s -w" -o "$OUT/bin/margince-migrate" ./cmd/migrate
  go build -ldflags="-s -w -X $BI.ReleaseVersion=$REL" -o "$OUT/bin/margince-worker" ./cmd/worker
)

# ---- Frontend (composed lane) -------------------------------------------------------
corepack enable
corepack prepare "$(node -p "require('./package.json').packageManager")" --activate
pnpm install --frozen-lockfile --prefer-offline --ignore-scripts --store-dir "$PNPM_STORE"
(cd build/composition-frontend/workspace &&
  pnpm install --no-frozen-lockfile --prefer-offline --ignore-scripts --store-dir "$PNPM_STORE")
(
  cd frontend
  export MARGINCE_COMPOSITION_FRONTEND="$SRC/build/composition/frontend"
  export MARGINCE_BUILD_REVISION="$SHA" MARGINCE_RELEASE_VERSION="$REL"
  pnpm gen:composed-types
  pnpm gen:events:composed
  pnpm build:composed
)
cp -a frontend/dist/. "$OUT/frontend/"

# ---- Install --------------------------------------------------------------------------
install -m 0755 scripts/deploy/api-entrypoint.sh scripts/deploy/worker-entrypoint.sh "$OUT/bin/"
# cmd/api takes its listen address only as a flag, and the entrypoint starts
# it without flags; this wrapper (first on the unit's PATH) keeps it on
# loopback behind nginx.
cat >"$OUT/bin/margince-api" <<'WRAPPER'
#!/bin/sh
exec /opt/margince/current/libexec/margince-api --addr 127.0.0.1:8080 "$@"
WRAPPER
chmod 0755 "$OUT/bin/margince-api"
echo "$REL" >"$OUT/release-version"
chmod -R a+rX,go-w "$OUT"

mkdir -p "$RELEASES"
rm -rf "${RELEASES:?}/$REL"
cp -a "$OUT" "$RELEASES/$REL"
ln -sfn "$RELEASES/$REL" /opt/margince/current.new
mv -Tf /opt/margince/current.new /opt/margince/current
log "installed release $REL"

# Keep the three newest releases for a manual rollback (ln -sfn + restart).
ls -1t "$RELEASES" | tail -n +4 | while read -r old; do
  if [[ "$old" != "$REL" ]]; then rm -rf "${RELEASES:?}/$old"; fi
done

if [[ "${MARGINCE_BUILD_NO_RESTART:-0}" != "1" ]] && systemctl is-enabled --quiet margince-api 2>/dev/null; then
  log "restarting services"
  systemctl restart margince-api
  systemctl restart margince-worker
  systemctl reload nginx
fi
