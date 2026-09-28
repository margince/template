#!/usr/bin/env bash
# trial.sh — a production-mode desktop bundle with a trial license, for a
# client to evaluate on a laptop (design Section 9.4).
#
# Steps, in order:
#
#   1. VERSION is a release version, and the platform is supported.
#   2. dist/trial/<name>-<v>-<platform>/ does not exist, or FORCE=1.
#   3. A trial license (scripts/license.sh trial). No license stops here,
#      before the build. There is no fallback to development mode.
#   4. The desktop build: ${TRIAL_DESKTOP_CMD:-make desktop} VERSION=<v>.
#   5. build/desktop/margince is copied to the output directory.
#   6. MARGINCE_LICENSE and MARGINCE_ENV=production are written into the
#      bundle's margince.env. The launcher reads that file from the folder it
#      runs in (core/desktop/launcher/layout.go, envPath) and passes each
#      KEY=value to the api and the worker; a value there overrides the
#      launcher's default MARGINCE_ENV=dev (services.go, childEnv).
#   7. When data.dataset is set, its reference goes to data/demo/DATASET.txt,
#      the directory the desktop seeding reads, and the seeding command is
#      printed.
#   8. TRIAL.txt: name, version, core version, and the license expiry.
#
# The license value is never printed. It is passed between steps in files
# with mode 600, never on a command line.
#
# Usage: bash scripts/trial.sh <version>   (or: make trial VERSION=<v> [FORCE=1])
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

version="${1:-}"
is_release_version "$version" ||
  die "trial: VERSION '$version' is not a release version (vX.Y.Z or vX.Y.Z-rc.N)"

# trial_platform — the output directory's platform suffix.
trial_platform() {
  local s m
  s="$(uname -s)"
  m="$(uname -m)"
  case "$s" in
    Darwin)
      case "$m" in
        arm64|aarch64) echo macos-arm64 ;;
        x86_64)        echo macos-x64 ;;
        *) return 1 ;;
      esac ;;
    MINGW*|MSYS*)
      case "$m" in
        x86_64) echo windows-x64 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}
platform="$(trial_platform)" ||
  die "trial: unsupported platform $(uname -s) $(uname -m) (want macOS arm64 or x86_64, or Windows x86_64)"

name="$(instance_get name)" || die "trial: cannot read instance.yaml: name"
core="$(instance_get core)" || die "trial: cannot read instance.yaml: core"
# Exit 2 means data.dataset is absent, which is allowed. Anything else is an
# unreadable file.
dataset=""
ds_rc=0
dataset="$(instance_get data.dataset 2>/dev/null)" || ds_rc=$?
case "$ds_rc" in
  0) ;;
  2) dataset="" ;;
  *) die "trial: cannot read instance.yaml: data.dataset" ;;
esac

bundle="$name-$version-$platform"
out_parent="$ROOT/dist/trial"
out="$out_parent/$bundle"
if [ -e "$out" ] && [ "${FORCE:-}" != 1 ]; then
  die "trial: $out exists; pass FORCE=1 to replace it"
fi

# The license lives in a private temporary directory until it is written into
# the bundle. The staging directory is created after the build, beside the
# output, so the final move is a rename.
lic_dir="$(mktemp -d)"
work=""
trap 'rm -rf "$lic_dir" ${work:+"$work"}' EXIT
chmod 700 "$lic_dir"
license_file="$lic_dir/license"

bash scripts/license.sh trial "$license_file" ||
  die "trial: no trial license; nothing was built"

# TRIAL_DESKTOP_CMD is split into words on purpose: it is a command line
# (the default is `make desktop`), and the tests set it to a stub.
${TRIAL_DESKTOP_CMD:-make desktop} VERSION="$version" ||
  die "trial: the desktop build failed"

src="$ROOT/build/desktop/margince"
[ -d "$src" ] || die "trial: the desktop build produced no $src"

mkdir -p "$out_parent"
work="$(mktemp -d "$out_parent/.$bundle.XXXXXX")"
chmod 700 "$work"
staged="$work/$bundle"
cp -Rp "$src" "$staged"

# set_env_file <env file> <license file> — MARGINCE_LICENSE and
# MARGINCE_ENV=production, each set exactly once in the file. The first line
# that assigns the key, commented out or not, is replaced in place so the
# launcher's annotation stays beside it; later assignments are removed,
# because the launcher takes the last value of a key. The rest of the file is
# kept. The license is read from its file, so it is never in argv.
python3 - "$staged/margince.env" "$license_file" <<'PY'
import os, re, sys, tempfile

env_path, license_path = sys.argv[1:3]
with open(license_path) as f:
    license_value = f.read().strip()
# A line break would end the assignment and start another line in the file.
if not license_value or re.search(r"\s", license_value):
    sys.exit("trial: the trial license is empty or contains whitespace; refusing to write it")
wanted = [("MARGINCE_LICENSE", license_value), ("MARGINCE_ENV", "production")]

lines = []
if os.path.exists(env_path):
    with open(env_path) as f:
        lines = f.read().splitlines()

for key, value in wanted:
    pattern = re.compile(r"^\s*#?\s*(export\s+)?" + key + r"\s*=")
    out, placed = [], False
    for line in lines:
        if pattern.match(line):
            if not placed:
                out.append(key + "=" + value)
                placed = True
            elif not line.lstrip().startswith("#"):
                continue
            else:
                out.append(line)
        else:
            out.append(line)
    if not placed:
        out.append(key + "=" + value)
    lines = out

directory = os.path.dirname(env_path) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".margince.env.")
try:
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, env_path)
except BaseException:
    os.unlink(tmp)
    raise
PY

# The expiry, from the JWT payload's exp claim. The payload is the second
# dot-separated segment, base64url without padding. Only the date leaves
# this step; an opaque or malformed license yields "".
expires="$(python3 - "$license_file" <<'PY'
import base64, datetime, json, sys
try:
    with open(sys.argv[1]) as f:
        parts = f.read().strip().split(".")
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    exp = json.loads(base64.urlsafe_b64decode(payload))["exp"]
    when = datetime.datetime.fromtimestamp(int(exp), datetime.timezone.utc)
    sys.stdout.write(when.strftime("%Y-%m-%dT%H:%M:%SZ"))
except Exception:
    pass
PY
)"

dataset_url=""
dataset_ref=""
if [ -n "$dataset" ]; then
  # Split at the LAST @: an scp-style URL (git@host:org/repo) has its own.
  dataset_url="${dataset%@*}"
  dataset_ref="${dataset##*@}"
  mkdir -p "$staged/data/demo"
  cat > "$staged/data/demo/DATASET.txt" <<EOF
# The demo dataset for this trial bundle (instance.yaml data.dataset).
# Clone it into this directory; the desktop seeding reads data/demo.
url: $dataset_url
ref: $dataset_ref
EOF
fi

{
  echo "Margince trial bundle"
  echo
  printf '%-10s %s\n' name "$name"
  printf '%-10s %s\n' version "$version"
  printf '%-10s %s\n' core "$core"
  printf '%-10s %s\n' platform "$platform"
  printf '%-10s %s\n' mode production
  if [ -n "$expires" ]; then
    printf '%-10s %s\n' expires "$expires"
  else
    printf '%-10s %s\n' expires "unknown (the license has no readable exp claim)"
  fi
  if [ -n "$dataset" ]; then
    printf '%-10s %s at %s\n' dataset "$dataset_url" "$dataset_ref"
  fi
} > "$staged/TRIAL.txt"

# The staged bundle replaces the output only now, so a failure in any step
# above leaves an existing output directory as it was.
rm -rf "$out"
mv "$staged" "$out"

printf 'trial: %s\n' "$out"
if [ -n "$expires" ]; then
  printf 'trial: production mode, trial license expires %s\n' "$expires"
else
  printf 'trial: production mode, trial license (expiry unknown)\n'
fi
if [ -n "$dataset" ]; then
  clone="$out/data/demo/dataset"
  printf 'trial: data.dataset is %s at %s. After the first start, seed it:\n' "$dataset_url" "$dataset_ref"
  printf '  git clone %s "%s"\n' "$dataset_url" "$clone"
  printf '  git -C "%s" checkout %s\n' "$clone" "$dataset_ref"
  printf '  make desktop-seed DATASET="%s"\n' "$clone"
  if [ ! -e "$out/Load Demo Data.command" ] && [ ! -e "$out/Load Demo Data.cmd" ]; then
    printf 'trial: note: this bundle has no demo loader. It is built only when the desktop\n'
    printf '       build can reach the dataset: run make trial with DATASET=<checkout>.\n'
  fi
fi
