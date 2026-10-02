#!/usr/bin/env bash
# make deploy step verify for this stack (hooks/lib.sh).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
step_verify
