#!/usr/bin/env bash
# A reusable workflow gets the secrets it is PASSED, and never the caller's.
#
# The defect this exists for shipped four releases. desktop-windows.yml and
# desktop-macos.yml read DATASET_DEPLOY_KEY to decide whether to seed the
# folder they build. Both are called by release.yml through
# `uses:`, neither declared the secret under `workflow_call:`, and no call site
# passed it — so in every release the key read empty, the dataset check reported
# it unavailable, every seeding step skipped, and the lane went GREEN shipping an
# empty folder. It was only ever exercised by `workflow_dispatch`, which runs in
# the repository's own context and therefore sees the secret; that is why the
# feature was proved working twice and still never reached a release.
#
# Nothing fails here at runtime. The fallback is deliberate and correct for a
# fork with no key, so the only place this can be caught is the wiring.
#
# Usage: bash scripts/workflow-wiring.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../.github/workflows"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# The block a top-level key owns: from that key to the next line indented no
# further than it. Used for `workflow_call:` and for one job's body.
block_of() { awk -v key="$1" '
  $0 ~ "^[[:space:]]*" key "[[:space:]]*:" && !started { match($0, /^[ ]*/); ind = RLENGTH; started = 1; print; next }
  started {
    if ($0 ~ /[^[:space:]]/) { match($0, /^[ ]*/); if (RLENGTH <= ind) exit }
    print
  }' "$2"; }

for f in "$WF"/*.yml; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  grep -qE '^[[:space:]]*workflow_call[[:space:]]*:' "$f" || continue

  # Every secret this workflow READS, minus GITHUB_TOKEN, which is always there.
  reads="$(grep -oE 'secrets\.[A-Za-z0-9_]+' "$f" | sed 's/secrets\.//' \
             | grep -v '^GITHUB_TOKEN$' | sort -u || true)"
  [ -n "$reads" ] || { ok "$name is callable and reads no secret"; continue; }

  declared="$(block_of workflow_call "$f" | grep -oE '^[[:space:]]{4,}[A-Za-z0-9_]+[[:space:]]*:' \
                | tr -d ' :' | sort -u || true)"

  for s in $reads; do
    if printf '%s\n' "$declared" | grep -qx "$s"; then
      ok "$name declares $s under workflow_call"
    else
      fail "$name reads secrets.$s but does not declare it under \`workflow_call:\`.
      A called workflow inherits NOTHING, so every caller silently hands it an
      empty value and whatever that value gates is skipped, green."
    fi

    # And every caller has to actually pass it.
    for caller in "$WF"/*.yml; do
      grep -q "uses: ./.github/workflows/$name" "$caller" || continue
      cname="$(basename "$caller")"
      passed=no
      # Look at each job in the caller that uses this workflow.
      while IFS= read -r job; do
        body="$(block_of "$job" "$caller")"
        printf '%s\n' "$body" | grep -q "uses: ./.github/workflows/$name" || continue
        if printf '%s\n' "$body" | grep -qE 'secrets:[[:space:]]*inherit' \
           || printf '%s\n' "$body" | grep -q "$s:"; then
          passed=yes
        fi
      done < <(grep -oE '^  [A-Za-z0-9_-]+:' "$caller" | tr -d ' :')
      if [ "$passed" = yes ]; then
        ok "$cname passes $s to $name"
      else
        fail "$cname calls $name but passes it no $s.
      The called workflow reads that secret; unpassed it reads empty, and what it
      gates is skipped without failing anything."
      fi
    done
  done
done

# deploy.yml runs by hand, from a release tag, in a GitHub Environment named
# by its own input, and must never let that input reach a shell verbatim: a
# workflow_dispatch input is attacker-controlled text the same as a pull
# request title, and `${{ inputs.x }}` spliced into a `run:` script is
# injected before the shell ever sees a variable. The job passes it through
# `env:` instead, which is opaque to the shell's parser.
DEPLOY_WF="$WF/deploy.yml"
if [ -e "$DEPLOY_WF" ]; then
  ok "deploy.yml exists"

  on_block="$(block_of on "$DEPLOY_WF")"
  if printf '%s\n' "$on_block" | grep -qE '^[[:space:]]{2}(push|pull_request|schedule|workflow_call)[[:space:]]*:'; then
    fail "deploy.yml triggers on more than workflow_dispatch"
  elif printf '%s\n' "$on_block" | grep -qE '^[[:space:]]{2}workflow_dispatch[[:space:]]*:'; then
    ok "deploy.yml triggers only on workflow_dispatch"
  else
    fail "deploy.yml does not trigger on workflow_dispatch"
  fi

  if grep -qE '^[[:space:]]*environment:[[:space:]]*\$\{\{[[:space:]]*inputs\.environment[[:space:]]*\}\}' "$DEPLOY_WF"; then
    ok "deploy.yml runs its job in the environment named by inputs.environment"
  else
    fail "deploy.yml does not set environment: \${{ inputs.environment }}"
  fi

  # The release is the tag the run was dispatched from, never a free-form
  # input: an input let the hooks of one ref deploy the images of another.
  if printf '%s\n' "$on_block" | grep -qE '^[[:space:]]+version[[:space:]]*:'; then
    fail "deploy.yml still has a version input; the release is github.ref_name"
  else
    ok "deploy.yml has no version input"
  fi
  if grep -qE 'REF_TYPE:[[:space:]]*\$\{\{[[:space:]]*github\.ref_type[[:space:]]*\}\}' "$DEPLOY_WF" \
     && grep -qF '"$REF_TYPE" != tag' "$DEPLOY_WF" \
     && grep -qF '"$REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$' "$DEPLOY_WF"; then
    ok "deploy.yml refuses a run not dispatched from a release tag"
  else
    fail "deploy.yml does not guard github.ref_type == tag and ref_name ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?\$ through env:"
  fi
  first_step="$(awk '/^[[:space:]]*steps:/ {s=1; next} s && /^[[:space:]]*- / {n++} n==1 {print} n>1 {exit}' "$DEPLOY_WF")"
  if printf '%s\n' "$first_step" | grep -qF 'github.ref_type'; then
    ok "deploy.yml checks the tag in its first step, before checkout"
  else
    fail "deploy.yml's first step is not the release-tag guard"
  fi
  if grep -qE 'DEPLOY_RELEASE:[[:space:]]*\$\{\{[[:space:]]*github\.ref_name[[:space:]]*\}\}' "$DEPLOY_WF"; then
    ok "deploy.yml deploys VERSION=github.ref_name"
  else
    fail "deploy.yml does not pass github.ref_name as the release"
  fi

  if grep -qE '^[[:space:]]*run:.*make deploy\b' "$DEPLOY_WF"; then
    ok "deploy.yml runs make deploy"
  else
    fail "deploy.yml does not run make deploy"
  fi

  # The `environment:` job key is resolved by GitHub before any step runs, so
  # a bad name still resolves an environment before this can object -- but it
  # still has to stop the job, before checkout finishes or any secret is
  # exported, on a name workflow_dispatch let through free-form.
  # With [[ =~ ]] on the whole value: `printf | grep` matches line by line, so
  # a name with an embedded newline passed if any one line was well-formed.
  if grep -qF '[[ ! "$DEPLOY_TARGET" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]' "$DEPLOY_WF"; then
    ok "deploy.yml validates the environment name with [[ =~ ]]"
  else
    fail "deploy.yml does not validate inputs.environment with [[ \"\$DEPLOY_TARGET\" =~ ^[a-z0-9]+(-[a-z0-9]+)*\$ ]]"
  fi

  # checkout, then setup-go, then the instance.yaml lookup, then the export:
  # a well-formed name that is not an environment of this instance stops the
  # job before any secret or variable is exported.
  order="$(grep -nE 'actions/checkout@|actions/setup-go@|name: Environment is in instance.yaml|name: Export the environment|name: Deploy$' "$DEPLOY_WF" | cut -d: -f1 | tr '\n' ' ')"
  set -- $order
  if [ "$#" -eq 5 ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ] && [ "$3" -lt "$4" ] && [ "$4" -lt "$5" ] \
     && grep -qF 'instance_get "deploy.$DEPLOY_TARGET.adapter"' "$DEPLOY_WF"; then
    ok "deploy.yml looks the environment up in instance.yaml before exporting anything"
  else
    fail "deploy.yml steps are not checkout -> setup-go -> Environment is in instance.yaml -> export -> deploy (lines: $order)"
  fi

  # The default shell has no pipefail: `jq ... | while read` would hide a jq
  # failure. Every run: step names bash, which adds -o pipefail.
  runs="$(grep -cE '^[[:space:]]*run:' "$DEPLOY_WF")"
  shells="$(grep -cE '^[[:space:]]*shell:[[:space:]]*bash[[:space:]]*$' "$DEPLOY_WF")"
  if [ "$runs" -eq "$shells" ]; then
    ok "deploy.yml sets shell: bash on each of its $runs run steps"
  else
    fail "deploy.yml has $runs run steps but $shells shell: bash lines"
  fi

  # A secret named PATH, GIT_*, GITHUB_*, BASH_ENV and the like would shadow a
  # variable the runner, git or a later step relies on. BASH_ENV stands in for
  # the whole deny list here: a shell-startup hook is the sharpest of them,
  # since a secret by that name would run as code the moment any later step's
  # shell starts, not merely read as data.
  # Go's and make's variables are denied by shape (no underscore), not by a
  # GO/MAKE prefix, which also swallowed GOOGLE_* and MAKER_* names.
  if grep -qF "deny_exact='PATH HOME SHELL IFS ENV BASH_ENV NODE_OPTIONS CDPATH PROMPT_COMMAND TMPDIR MFLAGS MAKE_TERMOUT MAKE_TERMERR'" "$DEPLOY_WF" \
     && grep -qF "deny_prefix='LD_ DYLD_ GITHUB_ RUNNER_ ACTIONS_ GIT_'" "$DEPLOY_WF" \
     && grep -qF "deny_shape='^GO[A-Z0-9]*\$ ^MAKE[A-Z0-9]*\$'" "$DEPLOY_WF" \
     && grep -qF '[[ "$name" =~ $re ]] && skip=1' "$DEPLOY_WF"; then
    ok "deploy.yml filters exported names against the documented deny list"
  else
    fail "deploy.yml's deny list is not exactly the documented one (exact: ... TMPDIR MFLAGS MAKE_TERMOUT MAKE_TERMERR; prefixes: ... GIT_; shapes: ^GO[A-Z0-9]*\$ ^MAKE[A-Z0-9]*\$)"
  fi

  if grep -qE 'VARS_JSON:[[:space:]]*\$\{\{[[:space:]]*toJSON\(vars\)[[:space:]]*\}\}' "$DEPLOY_WF" \
     && grep -qF 'export_json variable "$VARS_JSON"' "$DEPLOY_WF" \
     && grep -qF 'export_json secret "$SECRETS_JSON"' "$DEPLOY_WF"; then
    ok "deploy.yml exports the environment's variables and secrets through the same filter"
  else
    fail "deploy.yml does not export toJSON(vars) and toJSON(secrets) through export_json"
  fi

  if grep -qE '^[[:space:]]*persist-credentials:[[:space:]]*false[[:space:]]*$' "$DEPLOY_WF"; then
    ok "deploy.yml's checkout does not persist a credential past the job"
  else
    fail "deploy.yml's checkout does not set persist-credentials: false"
  fi

  # Every line that belongs to a `run:` step, single-line or the body of a
  # `run: |` block, collected the same way block_of collects a top-level key's
  # body: from the `run:` line until indentation returns to its own level or
  # less.
  run_lines="$(awk '
    /^[[:space:]]*run:[[:space:]]*[|>]/ {
      match($0, /^[ ]*/); ind = RLENGTH; inrun = 1; print; next
    }
    /^[[:space:]]*run:/ { print; inrun = 0; next }
    inrun {
      if ($0 ~ /[^[:space:]]/) {
        match($0, /^[ ]*/)
        if (RLENGTH <= ind) { inrun = 0 } else { print }
      } else { print }
    }
  ' "$DEPLOY_WF")"
  if printf '%s\n' "$run_lines" | grep -qF '${{ inputs.'; then
    fail "deploy.yml templates \${{ inputs. directly into a run: step.
      inputs.environment must reach the shell through
      env:, never through \${{ }} inside run:, or a crafted input injects
      shell code."
  else
    ok "deploy.yml never templates \${{ inputs. into a run: step"
  fi
else
  fail "deploy.yml is missing"
fi

# lifecycle.yml runs the whole instance lifecycle, which is slow — `make
# new-instance` and the scratch template clone it drives both need a full
# history, and every action it calls must be pinned by SHA like every other
# workflow here.
LIFECYCLE_WF="$WF/lifecycle.yml"
if [ -e "$LIFECYCLE_WF" ]; then
  ok "lifecycle.yml exists"

  # .github/workflows/ is template-owned, so every instance inherits this
  # file unchanged and cannot remove it (check-template rejects that). An
  # instance has no `make new-instance` to drive, so the job must not run
  # there. A job-level `if:` cannot call hashFiles() (it runs before any
  # checkout), so the guard cannot be a job-level `if: github.repository ==
  # ...` either — that would also name this repository. Instead: checkout
  # WITHOUT submodules, a step reads whether .template-version exists into a
  # step output, and every later step (submodule init and the lifecycle run
  # alike) repeats `if: steps.template.outputs.template == 'true'`, since
  # nothing job-level protects them anymore.
  job_block="$(block_of lifecycle "$LIFECYCLE_WF")"
  if printf '%s\n' "$job_block" | grep -qE "github\.repository[[:space:]]*=="; then
    fail "lifecycle.yml's job still guards on github.repository == ... — that names this repository, and a job-level if: cannot call hashFiles() anyway; guard each step on a step output instead"
  else
    ok "lifecycle.yml's job has no github.repository == guard"
  fi

  if printf '%s\n' "$job_block" | grep -qE "^[[:space:]]*id:[[:space:]]*template[[:space:]]*\$"; then
    ok "lifecycle.yml has a step id: template"
  else
    fail "lifecycle.yml has no step id: template to hold the .template-version check"
  fi

  if printf '%s\n' "$job_block" | grep -qF '.template-version' \
     && printf '%s\n' "$job_block" | grep -qF 'GITHUB_OUTPUT'; then
    ok "lifecycle.yml's template step reads .template-version and writes to GITHUB_OUTPUT"
  else
    fail "lifecycle.yml's template step does not read .template-version into GITHUB_OUTPUT"
  fi

  guard="if: steps.template.outputs.template == 'true'"
  guard_count="$(printf '%s\n' "$job_block" | grep -cF "$guard" || true)"
  step_count="$(printf '%s\n' "$job_block" | grep -cE '^[[:space:]]*- (uses:|name:)' || true)"
  # Every step except the checkout and the template check itself must carry
  # the guard: nothing job-level does, any more.
  if [ "$guard_count" -gt 0 ] && [ "$guard_count" -eq "$((step_count - 2))" ]; then
    ok "every step after checkout and the template check guards on \`$guard\` ($guard_count of $step_count steps)"
  else
    fail "not every later step guards on \`$guard\` ($guard_count guarded of $step_count steps; want $((step_count - 2)))"
  fi

  if grep -qE '^[[:space:]]*run:[[:space:]]*make test-lifecycle[[:space:]]*$' "$LIFECYCLE_WF"; then
    ok "lifecycle.yml runs make test-lifecycle"
  else
    fail "lifecycle.yml does not run make test-lifecycle"
  fi

  if grep -qE '^[[:space:]]*timeout-minutes[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*$' "$LIFECYCLE_WF"; then
    ok "lifecycle.yml sets timeout-minutes"
  else
    fail "lifecycle.yml has no timeout-minutes — a hung instance lifecycle would run until the runner's own default limit"
  fi

  unpinned="$(grep -oE 'uses:[[:space:]]*[^[:space:]]+' "$LIFECYCLE_WF" \
    | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)"
  if [ -z "$unpinned" ]; then
    ok "lifecycle.yml pins every \`uses:\` to a 40-hex SHA"
  else
    fail "lifecycle.yml has a \`uses:\` not pinned to a 40-hex commit SHA: $unpinned"
  fi

  # fetch-depth: 0, not the checkout default: `make new-instance` and the
  # scratch template clone both need full history, which a shallow checkout
  # does not have.
  checkout_block="$(awk '
    /uses:[[:space:]]*actions\/checkout@/ { match($0, /^[ ]*/); ind = RLENGTH; started = 1; print; next }
    started {
      if ($0 ~ /[^[:space:]]/) { match($0, /^[ ]*/); if (RLENGTH <= ind) exit }
      print
    }' "$LIFECYCLE_WF")"
  if printf '%s\n' "$checkout_block" | grep -qE 'fetch-depth:[[:space:]]*0[[:space:]]*$'; then
    ok "lifecycle.yml's checkout sets fetch-depth: 0"
  else
    fail "lifecycle.yml's checkout does not set fetch-depth: 0"
  fi

  # The first checkout must NOT fetch submodules: it runs before the template
  # guard, so it has to be cheap enough for an instance to pay for it too.
  # Submodule init happens later, behind the guard.
  if printf '%s\n' "$checkout_block" | grep -qE 'submodules:'; then
    fail "lifecycle.yml's first checkout still fetches submodules unconditionally — it runs before the template guard and must not"
  else
    ok "lifecycle.yml's first checkout does not fetch submodules"
  fi
else
  fail "lifecycle.yml is missing"
fi

# release.yml: a release tag builds the three role images, smoke-tests them,
# pushes them only when the repository names a registry, and publishes the
# GitHub Release after that (design Section 9.2).
RELEASE_WF="$WF/release.yml"
if [ -e "$RELEASE_WF" ]; then
  on_block="$(block_of on "$RELEASE_WF")"
  if printf '%s\n' "$on_block" | grep -qE '^[[:space:]]+push:' \
     && printf '%s\n' "$on_block" | grep -qF "tags: ['v*']"; then
    ok "release.yml triggers on a pushed v* tag"
  else
    fail "release.yml does not trigger on push: tags: ['v*']"
  fi

  version_job="$(block_of version "$RELEASE_WF")"
  if printf '%s\n' "$version_job" | grep -qF '[[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$ ]]'; then
    ok "release.yml's version job checks the tag with the release pattern"
  else
    fail "release.yml's version job does not check [[ ! \"\$TAG\" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?\$ ]]"
  fi
  if printf '%s\n' "$version_job" | grep -qE '\*-rc\.\*\)[[:space:]]*prerelease=true' \
     && [ "$(printf '%s\n' "$version_job" | grep -c 'prerelease=true')" -eq 1 ]; then
    ok "release.yml sets prerelease=true only for -rc.N"
  else
    fail "release.yml does not set prerelease=true exactly for *-rc.*"
  fi

  images_job="$(block_of images "$RELEASE_WF")"
  if [ -z "$images_job" ]; then
    fail "release.yml has no images job"
  else
    ok "release.yml has an images job"
    needs="$(printf '%s\n' "$images_job" | grep -E '^[[:space:]]+needs:' | head -1)"
    if printf '%s\n' "$needs" | grep -qw version && printf '%s\n' "$needs" | grep -qw full-check; then
      ok "images needs version and full-check"
    else
      fail "images does not need version and full-check: $needs"
    fi
    pkg="$(printf '%s\n' "$images_job" | grep -nE '^[[:space:]]*run:.*make package' | head -1 | cut -d: -f1)"
    smk="$(printf '%s\n' "$images_job" | grep -nE '^[[:space:]]*run:.*make smoke' | head -1 | cut -d: -f1)"
    if [ -n "$pkg" ] && [ -n "$smk" ] && [ "$pkg" -lt "$smk" ]; then
      ok "images runs make package, then make smoke"
    else
      fail "images does not run make package and then make smoke (package line ${pkg:-none}, smoke line ${smk:-none})"
    fi
    if printf '%s\n' "$images_job" | grep -qF 'submodules: recursive'; then
      ok "images checks out the submodules"
    else
      fail "images does not check out with submodules: recursive"
    fi

    # The step that pushes, and only it, runs under vars.REGISTRY.
    push_step="$(printf '%s\n' "$images_job" | awk '
      /^[[:space:]]*- / { if (buf ~ /if:[[:space:]]*vars\.REGISTRY[[:space:]]*!=[[:space:]]*'"''"'/) print buf; buf = "" }
      { buf = buf $0 "\n" }
      END { if (buf ~ /if:[[:space:]]*vars\.REGISTRY[[:space:]]*!=[[:space:]]*'"''"'/) print buf }')"
    if [ -n "$push_step" ] \
       && printf '%s\n' "$push_step" | grep -qF 'PUSH=1' \
       && printf '%s\n' "$push_step" | grep -qF -- '--password-stdin' \
       && printf '%s\n' "$push_step" | grep -qF 'secrets.REGISTRY_USERNAME' \
       && printf '%s\n' "$push_step" | grep -qF 'secrets.REGISTRY_PASSWORD' \
       && printf '%s\n' "$push_step" | grep -qF 'image-list/images.txt'; then
      ok "images pushes under if: vars.REGISTRY != '' (login on standard input, digests to image-list/images.txt)"
    else
      fail "images has no step under if: vars.REGISTRY != '' that logs in with --password-stdin, runs PUSH=1 and writes image-list/images.txt"
    fi
    # The registry credential leaves the runner on every exit of the push
    # step, a failed push included: a trap on EXIT set before the login.
    trap_line="$(printf '%s\n' "$push_step" | grep -nE "trap .*docker logout .*EXIT" | head -1 | cut -d: -f1 || true)"
    login_line="$(printf '%s\n' "$push_step" | grep -nF -- '--password-stdin' | head -1 | cut -d: -f1 || true)"
    if [ -n "$trap_line" ] && [ -n "$login_line" ] && [ "$trap_line" -lt "$login_line" ]; then
      ok "the push step logs out of the registry on every exit (trap set before login)"
    else
      fail "the push step does not set a trap ... docker logout ... EXIT before docker login"
    fi

    # The image list travels as an artifact. A job output is dropped by
    # GitHub when it contains a secret's value, and an image name can
    # contain the registry user name.
    outputs_block="$(printf '%s\n' "$images_job" | awk '
      /^    outputs:/ {o=1; next}
      o && /^    [^ ]/ {exit}
      o {print}')"
    if printf '%s\n' "$outputs_block" | grep -qE '^[[:space:]]+images[[:space:]]*:'; then
      fail "images still exports the image list as a job output"
    else
      ok "images does not export the image list as a job output"
    fi
    upload="$(printf '%s\n' "$images_job" | awk '
      /uses:[[:space:]]*actions\/upload-artifact@/ { match($0, /^[ ]*/); ind = RLENGTH; started = 1; print; next }
      started { if ($0 ~ /[^[:space:]]/) { match($0, /^[ ]*/); if (RLENGTH <= ind) exit } print }')"
    if printf '%s\n' "$upload" | grep -qE 'actions/upload-artifact@[0-9a-f]{40}' \
       && printf '%s\n' "$upload" | grep -qF 'name: margince-images-${{ needs.version.outputs.version }}' \
       && printf '%s\n' "$upload" | grep -qF 'image-list/images.txt' \
       && printf '%s\n' "$upload" | grep -qE 'if-no-files-found:[[:space:]]*error'; then
      ok "images uploads image-list/images.txt as margince-images-<version> (pinned, if-no-files-found: error)"
    else
      fail "images does not upload image-list/images.txt with a SHA-pinned upload-artifact, name margince-images-\${{ needs.version.outputs.version }}, if-no-files-found: error"
    fi
    if printf '%s\n' "$images_job" | grep -B6 'GITHUB_STEP_SUMMARY' | grep -qF 'image-list/images.txt'; then
      ok "images writes the image list to the job summary"
    else
      fail "images does not write image-list/images.txt to \$GITHUB_STEP_SUMMARY"
    fi
    pushes="$(printf '%s\n' "$images_job" | grep -cE 'PUSH=1|docker push|--push' || true)"
    in_step="$(printf '%s\n' "$push_step" | grep -cE 'PUSH=1|docker push|--push' || true)"
    if [ "$pushes" -eq "$in_step" ]; then
      ok "nothing in images pushes outside the vars.REGISTRY step"
    else
      fail "images pushes outside the vars.REGISTRY step ($pushes push lines, $in_step inside it)"
    fi
    nopush_step="$(printf '%s\n' "$images_job" | awk '
      /^[[:space:]]*- / { if (buf ~ /if:[[:space:]]*vars\.REGISTRY[[:space:]]*==[[:space:]]*'"''"'/) print buf; buf = "" }
      { buf = buf $0 "\n" }
      END { if (buf ~ /if:[[:space:]]*vars\.REGISTRY[[:space:]]*==[[:space:]]*'"''"'/) print buf }')"
    if printf '%s\n' "$nopush_step" | grep -qF 'images were not pushed: REGISTRY is not set' \
       && printf '%s\n' "$nopush_step" | grep -qF 'image-list/images.txt'; then
      ok "without REGISTRY, images writes the not-pushed note to image-list/images.txt"
    else
      fail "no step under if: vars.REGISTRY == '' writes 'images were not pushed: REGISTRY is not set' to image-list/images.txt"
    fi

    # The all-in-one image (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md,
    # Section 11): built and smoke-tested after the role images' smoke test,
    # pushed only in the registry step, and its install scripts uploaded.
    aio_line="$(printf '%s\n' "$images_job" | grep -nE '^[[:space:]]*run:.*make aio VERSION' | head -1 | cut -d: -f1 || true)"
    aio_smoke_line="$(printf '%s\n' "$images_job" | grep -nE '^[[:space:]]*run:.*make aio-smoke' | head -1 | cut -d: -f1 || true)"
    if [ -n "$smk" ] && [ -n "$aio_line" ] && [ -n "$aio_smoke_line" ] && [ "$smk" -lt "$aio_line" ] && [ "$aio_line" -lt "$aio_smoke_line" ]; then
      ok "images runs make aio after make smoke, then make aio-smoke"
    else
      fail "images does not run make aio after make smoke and then make aio-smoke (smoke ${smk:-none}, aio ${aio_line:-none}, aio-smoke ${aio_smoke_line:-none})"
    fi
    if printf '%s\n' "$push_step" | grep -qE 'make aio VERSION="\$VERSION" PUSH=1' \
       && printf '%s\n' "$push_step" | grep -qF '/all-in-one:${VERSION}@${digest}'; then
      ok "the push step pushes the all-in-one image and lists it by digest"
    else
      fail "the push step does not run make aio ... PUSH=1 and list <repo>/all-in-one:<v>@<digest>"
    fi
    if printf '%s\n' "$images_job" | grep -qE '^[[:space:]]*run:.*make aio-scripts' \
       && printf '%s\n' "$images_job" | grep -qF 'name: margince-aio-scripts-${{ needs.version.outputs.version }}'; then
      ok "images writes the install scripts and uploads them as margince-aio-scripts-<version>"
    else
      fail "images does not run make aio-scripts and upload margince-aio-scripts-\${{ needs.version.outputs.version }}"
    fi
  fi

  publish_job="$(block_of publish "$RELEASE_WF")"
  needs="$(printf '%s\n' "$publish_job" | grep -E '^[[:space:]]+needs:' | head -1)"
  if printf '%s\n' "$needs" | grep -qw images; then
    ok "publish needs images"
  else
    fail "publish does not need images: $needs"
  fi
  if printf '%s\n' "$publish_job" | grep -qF 'needs.images.outputs.core'; then
    ok "publish reads the core version from the images job"
  else
    fail "publish does not read needs.images.outputs.core for the release notes"
  fi
  if printf '%s\n' "$publish_job" | grep -qF 'needs.images.outputs.images'; then
    fail "publish still reads the image list from a job output"
  else
    ok "publish does not read the image list from a job output"
  fi
  download="$(printf '%s\n' "$publish_job" | grep -A3 -E 'uses:[[:space:]]*actions/download-artifact@[0-9a-f]{40}' || true)"
  if printf '%s\n' "$download" | grep -qF 'name: margince-images-${{ needs.version.outputs.version }}' \
     && printf '%s\n' "$download" | grep -qE 'path:[[:space:]]*image-list[[:space:]]*$'; then
    ok "publish downloads margince-images-<version> into image-list"
  else
    fail "publish does not download margince-images-\${{ needs.version.outputs.version }} to path: image-list"
  fi
  if printf '%s\n' "$publish_job" | grep -qF '[ ! -s image-list/images.txt ]' \
     && printf '%s\n' "$publish_job" | grep -A2 -F '[ ! -s image-list/images.txt ]' | grep -qF '::error::' \
     && printf '%s\n' "$publish_job" | grep -qF "sed '/^\$/d; s/^/- /' image-list/images.txt"; then
    ok "publish builds the notes from image-list/images.txt and fails with ::error:: when it is missing or empty"
  else
    fail "publish does not refuse a missing or empty image-list/images.txt with ::error:: and build the notes from it"
  fi
  # The install scripts pull the pushed image. Without a push their image
  # name has no registry, and a tester's docker pull would resolve it on the
  # default public registry: they are attached and advertised only after a push.
  if printf '%s\n' "$publish_job" | grep -qF 'name: margince-aio-scripts-${{ needs.version.outputs.version }}' \
     && [ "$(printf '%s\n' "$publish_job" | grep -cF "if ! grep -qF 'images were not pushed' image-list/images.txt; then")" -ge 2 ] \
     && printf '%s\n' "$publish_job" | grep -qF 'assets+=(dist/install.sh dist/install.ps1)' \
     && [ "$(printf '%s\n' "$publish_job" | grep -cF '"${assets[@]}"')" -eq 2 ] \
     && ! printf '%s\n' "$publish_job" | grep -qF 'dist/*.zip dist/install.sh'; then
    ok "publish attaches and advertises install.sh and install.ps1 only when the images were pushed"
  else
    fail "publish does not attach dist/install.sh and dist/install.ps1 (and write 'Try it') only when image-list/images.txt lists pushed images"
  fi
  # --prerelease is added in exactly one place, behind the version job's flag.
  pre_lines="$(grep -c -- '--prerelease' "$RELEASE_WF" || true)"
  if [ "$pre_lines" -eq 1 ] \
     && grep -B2 -- '--prerelease' "$RELEASE_WF" | grep -qF 'if [ "$PRERELEASE" = true ]' \
     && printf '%s\n' "$publish_job" | grep -qE 'PRERELEASE:[[:space:]]*\$\{\{[[:space:]]*needs\.version\.outputs\.prerelease'; then
    ok "publish adds --prerelease only when the version job says -rc"
  else
    fail "--prerelease is not added once, behind PRERELEASE from needs.version.outputs.prerelease"
  fi

  # A secret is passed through env:, never templated into a script.
  if awk '/^[[:space:]]*run:/ {r=1} /^[[:space:]]*(env|with|if|uses|name|id|shell):/ {r=0} r' "$RELEASE_WF" | grep -qF '${{ secrets.'; then
    fail "release.yml templates \${{ secrets. into a run: script"
  else
    ok "release.yml never templates \${{ secrets. into a run: script"
  fi
else
  fail "release.yml is missing"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nworkflow-wiring: all checks passed\n'
