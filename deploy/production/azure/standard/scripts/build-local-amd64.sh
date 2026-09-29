#!/usr/bin/env bash
# x86 (linux/amd64) images from a Mac, pushed to this stack's registry: the
# only images Azure Container Apps runs ("Linux-based (linux/amd64) container
# images are required", learn.microsoft.com/azure/container-apps/containers).
#
# On Apple silicon this cross-builds: the Dockerfile compiles Go and the SPA on
# the native build platform and only the thin runtime stages run under x86
# emulation. Called by build-images.sh (needs MARGINCE_REPO); usage: build-local-amd64.sh <tag>.
# Needs this machine's public IP in operator_ip_allowlist.
set -euo pipefail

tag="$1"
# The Margince source checkout to build from (it holds the Dockerfile).
repo_root="${MARGINCE_REPO:?set MARGINCE_REPO to your margince source checkout, e.g. export MARGINCE_REPO=~/src/margince}"
[[ -f "$repo_root/Dockerfile" ]] || { echo "no Dockerfile in $repo_root" >&2; exit 1; }
acr_server="$(terraform output -raw acr_login_server)"
acr_name="$(terraform output -raw acr_name)"

command -v docker >/dev/null || { echo "docker not found (start Colima: colima start)" >&2; exit 1; }
docker buildx version >/dev/null

# The runtime stages need x86 emulation in the Docker VM. Colima provides it
# with `colima start --vm-type vz --vz-rosetta` (or qemu binfmt).
if ! docker run --rm --platform linux/amd64 alpine:3 true >/dev/null 2>&1; then
  echo "This Docker VM cannot run linux/amd64 containers." >&2
  echo "Restart Colima with emulation: colima stop && colima start --vm-type vz --vz-rosetta" >&2
  exit 1
fi

az acr login --name "$acr_name"
digests=()
meta_dir="$(mktemp -d)"
trap 'rm -rf "$meta_dir"' EXIT
command -v jq >/dev/null || { echo "jq not found (brew install jq)" >&2; exit 1; }
for role in api worker web; do
  echo "==> $role (linux/amd64)"
  docker buildx build \
    --platform linux/amd64 \
    --target "$role" \
    --build-arg "MARGINCE_RELEASE_VERSION=$tag" \
    -t "$acr_server/$role:$tag" \
    -f "$repo_root/Dockerfile" \
    --metadata-file "$meta_dir/$role.json" \
    --push \
    "$repo_root"
  digests+=("$role = \"$(jq -r '.["containerimage.digest"]' "$meta_dir/$role.json")\"")
  # Lock the tag so a later push cannot change what it points to.
  az acr repository update --name "$acr_name" --image "$role:$tag" \
    --write-enabled false --delete-enabled false --output none \
    || echo "WARNING: could not lock $role:$tag (needs metadata write on the registry)" >&2
done
echo "Digests (optional image_digests in terraform.tfvars):"
printf '  %s\n' "${digests[@]}"

echo "Pushed api, worker, web as $tag to $acr_server. Set image_tag = \"$tag\" and terraform apply."
