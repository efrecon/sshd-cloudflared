#!/bin/sh

# Failsafe mode: stop on errors and unset vars
set -eu


# Root directory where this script is located
CF_SSHD_ROOTDIR=${CF_SSHD_ROOTDIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}

# Verbosity level
CF_SSHD_VERBOSE=${CF_SSHD_VERBOSE:-"0"}

CF_SSHD_GITHUB=${CF_SSHD_GITHUB:-""}

CF_SSHD_PORT=${CF_SSHD_PORT:-"2222"}

CF_SSHD_KNOWN_HOST=${CF_SSHD_KNOWN_HOST:-"sshd-cloudflared"}

CF_SSHD_DIE=${CF_SSHD_DIE:-"7d"}

CF_SSHD_TEMPLATE=${CF_SSHD_TEMPLATE:-"/usr/local/lib/sshd_config.tpl"}

CF_SSHD_SHELL=${CF_SSHD_SHELL:-"${SHELL:-"ash"}"}

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 establishes a cloudflare tunnel and arranges for ssh access" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^CF_SSHD_' | sed 's/^CF_SSHD_/    CF_SSHD_/g'
  exit "${1:-0}"
}

while getopts "g:s:vh-" opt; do
  case "$opt" in
    g) # GitHub account
      CF_SSHD_GITHUB="$OPTARG";;
    s) # Shell to use for the user, needs to be installed!
      CF_SSHD_SHELL="$OPTARG";;
    -) # End of options, everything are the paths to the files to upload
      break;;
    v) # Turn on verbosity, will otherwise log on errors/warnings only
      CF_SSHD_VERBOSE=1;;
    h) # Print help and exit
      usage;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# PML: Poor Man's Logging
_log() {
    printf '[%s] [%s] [%s] %s\n' \
      "$(basename "$0")" \
      "${2:-LOG}" \
      "$(date +'%Y%m%d-%H%M%S')" \
      "${1:-}" \
      >&2
}
# shellcheck disable=SC2015 # We are fine, this is just to never fail
trace() { [ "$CF_SSHD_VERBOSE" -ge "2" ] && _log "$1" DBG || true ; }
# shellcheck disable=SC2015 # We are fine, this is just to never fail
verbose() { [ "$CF_SSHD_VERBOSE" -ge "1" ] && _log "$1" NFO || true ; }
warn() { _log "$1" WRN; }
error() { _log "$1" ERR && exit 1; }

# Check the commands passed as parameters are available and exit on errors.
check_command() {
  for cmd; do
    if ! command -v "$cmd" >/dev/null; then
      error "$cmd not available. This is a stringent requirement. Cannot continue!"
    fi
  done
}

cleanup() {
  verbose "Killing processes"
  if [ -n "${pid_cloudflared:-}" ]; then
    kill "$pid_cloudflared"
  fi
  if [ -n "${pid_sshd:-}" ]; then
    kill "$pid_sshd"
  fi
  verbose "Removing state files"
  rm -rf "$CF_SSHD_DIR"
}

check_command jq cloudflared

# Make temporary directory inside account, to keep sshd happy
CF_SSHD_DIR="$(pwd)/.cf-sshd_$(head -c 16 /dev/urandom | base64 | tr -cd '[:alnum:]' | head -c 16)"
mkdir -p "$CF_SSHD_DIR"
chmod go-rwx "$CF_SSHD_DIR"
verbose "Created directory $CF_SSHD_DIR for internal settings, will be cleaned up"

verbose "SSHd settings in $CF_SSHD_DIR"
if [ -n "$CF_SSHD_GITHUB" ]; then
  verbose "Collecting public keys from github user $CF_SSHD_GITHUB"
  curl --silent --location "https://api.github.com/users/${CF_SSHD_GITHUB}/keys" |
    jq -r '.[].key' > "${CF_SSHD_DIR}/authorized_keys"
  chmod go-rwx "${CF_SSHD_DIR}/authorized_keys"
fi

if ! grep -q . "${CF_SSHD_DIR}/authorized_keys"; then
  error "Cannot initialise SSHd"
fi

verbose "Generating SSHd host keys"
ssh-keygen -q -f "${CF_SSHD_DIR}/ssh_host_rsa_key" -N '' -b 4096 -t rsa

verbose "Creating SSHd configuration at ${CF_SSHD_DIR}/sshd_config from $CF_SSHD_TEMPLATE"
sed \
  -e "s,\$PWD,${CF_SSHD_DIR},g" \
  -e "s,\$USER,$(id -un),g" \
  -e "s,\$PORT,${CF_SSHD_PORT},g" \
  -e "s,\$SHELL,${CF_SSHD_SHELL},g" \
  "$CF_SSHD_TEMPLATE" > "${CF_SSHD_DIR}/sshd_config"

verbose "Starting SSHd server"
/usr/sbin/sshd -f "${CF_SSHD_DIR}/sshd_config" -D -E "${CF_SSHD_DIR}/sshd.log" &
pid_sshd=$!

verbose 'Starting Cloudflare tunnel...'
cloudflared tunnel --no-autoupdate --url "tcp://localhost:$CF_SSHD_PORT" 2>&1 | tee "${CF_SSHD_DIR}/cloudflared.log" &
pid_cloudflared=$!

url=$(while ! grep -o 'https://.*\.trycloudflare.com' "${CF_SSHD_DIR}/cloudflared.log"; do sleep 1; done)
public_key=$(cut -d' ' -f1,2 < "${CF_SSHD_DIR}/ssh_host_rsa_key.pub")

echo ""
echo ""
echo 'Run the following command to connect:'
echo "    ssh-keygen -R $CF_SSHD_KNOWN_HOST && echo '$CF_SSHD_KNOWN_HOST $public_key' >> ~/.ssh/known_hosts && ssh -o ProxyCommand='cloudflared access tcp --hostname $url' $(id -un)@$CF_SSHD_KNOWN_HOST"
echo ""
echo 'Run the following command to connect without verification (DANGER!):'
echo "    ssh -o ProxyCommand='cloudflared access tcp --hostname $url' $(id -un)@$CF_SSHD_KNOWN_HOST -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new"
echo ""
echo ""

trap cleanup INT
trap cleanup TERM
sleep "$CF_SSHD_DIE"
cleanup