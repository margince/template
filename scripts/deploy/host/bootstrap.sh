#!/usr/bin/env bash
# deploy/host/bootstrap.sh — prepare a new server for a host adapter
# environment (make host-bootstrap, design Section 9.6).
#
# Over SSH (the same options as the host adapter: BatchMode, strict host key
# checking with HOST_KNOWN_HOSTS, HOST_SSH_KEY when set):
#
#   1. Reads /etc/os-release. Supported: Ubuntu 22.04 and 24.04, Amazon
#      Linux 2023. Any other system exits 1, naming it.
#   2. When `docker compose version` fails, installs Docker Engine and the
#      Compose plugin with the distribution's documented method:
#        Ubuntu             Docker's apt repository (docs.docker.com/engine/install/ubuntu)
#        Amazon Linux 2023  `dnf install docker`, and the Compose plugin
#                           binary from Docker's GitHub release (pinned
#                           version and SHA-256) in /usr/local/lib/docker/cli-plugins
#      An existing Compose older than 2.30.0 is reported and not replaced.
#      On Ubuntu, installed distribution packages that conflict with Docker's
#      (docker.io, docker-compose-v2, podman-docker, ...) stop the run with
#      their names and the removal command; nothing is removed.
#   3. Adds the SSH user to the `docker` group when it is not a member.
#
# Prints each change, or "host-bootstrap: <host> is ready (nothing to change)".
# The SSH user needs passwordless sudo (the default for ubuntu and ec2-user
# on EC2).
#
# Usage: bash scripts/deploy/host/bootstrap.sh <env>   (or: make host-bootstrap ENV=<env>)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The Compose plugin for Amazon Linux 2023 (its repositories do not ship it).
COMPOSE_VERSION=v2.39.4
COMPOSE_SHA256_X86_64=7af95166a730b87e172d4fc9aefea8725d3c6c7327d59149267b452114ddb7d4
COMPOSE_SHA256_AARCH64=49082844b87f03cdcd5f5bbef1ba8c9c897b7a2dfb80cea18d61ec8ca6117e0c

env="${1:-}"
[ -n "$env" ] || die "host-bootstrap: pass ENV=<environment>, e.g. make host-bootstrap ENV=prod"

if ! out="$(instance_validate 2>&1)"; then
  printf '%s\n' "$out" >&2
  die "host-bootstrap: instance.yaml is not valid"
fi
if adapter="$(instance_get "deploy.$env.adapter" 2>/dev/null)"; then :; else
  die "host-bootstrap: '$env' is not an environment in instance.yaml (deploy: $env: { adapter: host })"
fi
[ "$adapter" = host ] || die "host-bootstrap: environment '$env' uses the $adapter adapter; host-bootstrap is for the host adapter"
export DEPLOY_DIR="$ROOT/deploy/$env"

target="$(host_ssh_target)" || exit 1
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
host_ssh_setup "$state" "$target" || die "host-bootstrap: cannot set up SSH"

say() { printf 'host-bootstrap: %s\n' "$*"; }

os="$(host_ssh "cat /etc/os-release")" || die "host-bootstrap: cannot connect to $target over SSH, or it has no /etc/os-release"
# os_field <key> — a value from /etc/os-release, read as text, never run.
os_field() {
  printf '%s\n' "$os" | sed -n "s/^$1=//p" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
os_id="$(os_field ID)"
os_ver="$(os_field VERSION_ID)"
case "$os_id:$os_ver" in
  ubuntu:22.04|ubuntu:24.04|amzn:2023) ;;
  *) die "host-bootstrap: $target runs ${os_id:-an unknown system} ${os_ver:-}; supported: Ubuntu 22.04, Ubuntu 24.04, Amazon Linux 2023" ;;
esac

ubuntu_install() {
  cat <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
sudo -n apt-get update
sudo -n apt-get install -y ca-certificates curl
sudo -n install -m 0755 -d /etc/apt/keyrings
sudo -n curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo -n chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo -n tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo -n apt-get update
sudo -n apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo -n systemctl enable --now docker
sudo -n docker compose version
EOF
}

amzn_install() {
  cat <<EOF
set -e
sudo -n dnf install -y docker
sudo -n systemctl enable --now docker
arch=\$(uname -m)
case "\$arch" in
  x86_64) sum=$COMPOSE_SHA256_X86_64 ;;
  aarch64) sum=$COMPOSE_SHA256_AARCH64 ;;
  *) echo "no Docker Compose plugin build for \$arch" >&2; exit 1 ;;
esac
tmp=\$(mktemp -d)
curl -fsSL -o "\$tmp/docker-compose" "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-\$arch"
echo "\$sum  \$tmp/docker-compose" | sha256sum -c -
sudo -n install -d -m 0755 /usr/local/lib/docker/cli-plugins
sudo -n install -m 0755 "\$tmp/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
rm -rf "\$tmp"
sudo -n docker compose version
EOF
}

# The distribution's own container packages conflict with Docker's packages
# (docs.docker.com/engine/install/ubuntu, "Uninstall old versions").
# host-bootstrap does not remove software; it names them and stops.
UBUNTU_CONFLICTS="docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"
ubuntu_conflicts() {
  local listed
  listed="$(host_ssh "dpkg-query -W -f='\${db:Status-Abbrev} \${Package}\n' $UBUNTU_CONFLICTS 2>/dev/null || true")" ||
    die "host-bootstrap: cannot list the installed packages on $target"
  printf '%s\n' "$listed" | awk '$1 == "ii" { printf "%s ", $2 }' | sed 's/ $//'
}

changed=0
if v="$(host_ssh "docker compose version --short" 2>/dev/null)"; then
  host_version_at_least "$v" "$HOST_MIN_COMPOSE" ||
    die "host-bootstrap: $target has Docker Compose $v; the host adapter needs $HOST_MIN_COMPOSE or later. Upgrade it with the method it was installed with; host-bootstrap does not replace an existing installation"
else
  if [ "$os_id" = ubuntu ]; then
    conflicts="$(ubuntu_conflicts)"
    [ -z "$conflicts" ] ||
      die "host-bootstrap: $target has the distribution's packages $conflicts installed; they conflict with Docker's packages. Remove them first (sudo apt-get remove $conflicts), then run make host-bootstrap again"
    say "$target ($os_id $os_ver): installing Docker Engine and the Compose plugin"
    ubuntu_install | host_ssh "sh -s" || die "host-bootstrap: the Docker install on $target failed (see above)"
  else
    say "$target ($os_id $os_ver): installing Docker Engine and the Compose plugin"
    amzn_install | host_ssh "sh -s" || die "host-bootstrap: the Docker install on $target failed (see above)"
  fi
  v="$(host_ssh "docker compose version --short" 2>/dev/null)" ||
    die "host-bootstrap: the install finished, but 'docker compose version' still fails on $target"
  say "$target: installed Docker Engine and the Compose plugin ($v)"
  changed=1
fi

groups="$(host_ssh "id -nG")" || die "host-bootstrap: cannot read the groups of the SSH user on $target"
case " $groups " in
  *" docker "*) ;;
  *)
    host_ssh 'sudo -n usermod -aG docker "$(id -un)"' || die "host-bootstrap: cannot add the SSH user to the docker group on $target"
    say "$target: added ${target%%@*} to the docker group (effective from the next SSH login)"
    changed=1
    ;;
esac

if [ "$changed" = 0 ]; then
  say "$target is ready (nothing to change)"
else
  say "$target is ready"
fi
