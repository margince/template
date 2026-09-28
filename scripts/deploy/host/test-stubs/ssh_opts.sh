# shellcheck shell=bash
# ssh_opts.sh — option parsing shared by the ssh and scp stubs. Sourced.
# stub_parse_opts "$@" sets STUB_REST (the non-option arguments) and checks
# the options the host adapter must always pass. Exits 255 like ssh when a
# check fails.
stub_parse_opts() {
  local kh="" strict="" batch="" mode
  STUB_REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -o)
        case "$2" in
          UserKnownHostsFile=*) kh="${2#*=}" ;;
          StrictHostKeyChecking=*) strict="${2#*=}" ;;
          BatchMode=*) batch="${2#*=}" ;;
        esac
        shift 2 ;;
      -i)
        [ -f "$2" ] || { echo "stub: identity file $2 not found" >&2; exit 255; }
        mode="$(stub_mode "$2")"
        [ "$mode" = 600 ] || { echo "stub: identity file $2 has mode $mode, not 600" >&2; exit 255; }
        shift 2 ;;
      -p|-P|-l|-F|-J) shift 2 ;;
      --) shift; STUB_REST+=("$@"); break ;;
      -*) shift ;;
      *) STUB_REST+=("$1"); shift ;;
    esac
    # ssh stops option parsing at the host; the command's own words follow.
    if [ "${STUB_STOP_AT_HOST:-0}" = 1 ] && [ "${#STUB_REST[@]}" -gt 0 ]; then
      STUB_REST+=("$@"); break
    fi
  done
  [ "$batch" = yes ] || { echo "stub: BatchMode=yes is not set" >&2; exit 255; }
  [ "$strict" = yes ] || { echo "stub: StrictHostKeyChecking=yes is not set" >&2; exit 255; }
  [ -n "$kh" ] && [ -s "$kh" ] || { echo "stub: UserKnownHostsFile is missing or empty" >&2; exit 255; }
  mode="$(stub_mode "$kh")"
  [ "$mode" = 600 ] || { echo "stub: known hosts file has mode $mode, not 600" >&2; exit 255; }
  [ ! -e "$STUB_STATE/fail.ssh" ] || { echo "ssh: connect to host port 22: Connection refused" >&2; exit 255; }
}

stub_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# stub_rewrite <text> — /opt/margince moved under STUB_SERVER_ROOT.
stub_rewrite() {
  local text="$1" to
  if [ -n "${STUB_SERVER_ROOT:-}" ]; then
    to="$STUB_SERVER_ROOT/opt/margince"
    text="${text//\/opt\/margince/$to}"
  fi
  printf '%s' "$text"
}
