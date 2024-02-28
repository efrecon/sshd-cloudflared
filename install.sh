#!/bin/sh

# Shell sanity. Stop on errors and undefined variables.
set -eu

# The root location of the github site
: "${INSTALL_GITHUB:="https://github.com"}"

# Name of this project at GitHub
: "${INSTALL_PROJECT:="efrecon/sshd-cloudflared"}"

# Name of the cloudflared project at GitHub
: "${INSTALL_CLOUDFLARED:="cloudflare/cloudflared"}"

# The branch of this project to use for the installation
: "${INSTALL_BRANCH:="main"}"

# The name of the script to install and run
: "${INSTALL_SCRIPT:="cf-sshd.sh"}"

# Should we run the installed script? (all options after the -- are blindly
# passed)
: "${INSTALL_RUN:=false}"

# Level of verbosity, the higher the more verbose. All messages are sent to the
# stderr.
: "${INSTALL_VERBOSE:=0}"

# Where to send logs
: "${INSTALL_LOG:=2}"


usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "install.sh -- Install sshd-cloudflared and cloudflared, run it if requested}" && \
    grep "[[:space:]].) #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-zA-Z-])\)/-\1/'
  if [ -n "${2:-}" ]; then
    printf '\nCurrent state:\n'
    set | grep -E "^${2}_" | sed -E 's/^([A-Z])/  \1/g'
  fi
  exit "${1:-0}"
}

while getopts "b:i:rl:vh-" opt; do
  case "$opt" in
    b) # Branch to use for the installation
      INSTALL_BRANCH="$OPTARG";;
    i) # Name of the script to install and run
      INSTALL_SCRIPT="$OPTARG";;
    r) # Run the installed script
      INSTALL_RUN=true;;
    l) # Where to send logs
      INSTALL_LOG="$OPTARG";;
    v) # Increase verbosity, will otherwise log on errors/warnings only
      INSTALL_VERBOSE=$((INSTALL_VERBOSE+1));;
    h) # Print help and exit
      usage 0 "INSTALL";;
    -) # End of options, everything after is passed to the entrypoint of the Docker image.
      break;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# PML: Poor Man's Logging
_log() {
  # Capture level and shift it away, rest will be passed blindly to printf
  _lvl=${1:-LOG}; shift
  # shellcheck disable=SC2059 # We want to expand the format string
  printf '[%s] [%s] [%s] %s\n' \
    "install.sh" \
    "$_lvl" \
    "$(date +'%Y%m%d-%H%M%S')" \
    "$(printf "$@")" \
    >&"$INSTALL_LOG"
}
trace() { if [ "${INSTALL_VERBOSE:-0}" -ge "3" ]; then _log TRC "$@"; fi; }
debug() { if [ "${INSTALL_VERBOSE:-0}" -ge "2" ]; then _log DBG "$@"; fi; }
verbose() { if [ "${INSTALL_VERBOSE:-0}" -ge "1" ]; then _log NFO "$@"; fi; }
info() { if [ "${INSTALL_VERBOSE:-0}" -ge "1" ]; then _log NFO "$@"; fi; }
warn() { _log WRN "$@"; }
error() { _log ERR "$@" && exit 1; }

# shellcheck disable=SC2120 # Take none or one argument
to_lower() {
  if [ -z "${1:-}" ]; then
    tr '[:upper:]' '[:lower:]'
  else
    printf %s\\n "$1" | to_lower
  fi
}

is_true() {
  case "$(to_lower "${1:-}")" in
    1 | true | yes | y | on | t) return 0;;
    *) return 1;;
  esac
}

# Check if a command is available. If not, print a warning and return 1.
check_command() {
  trace "Checking $1 is an accessible command"
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Command not found: %s" "$1"
    return 1
  fi
}

# Run the command passed as arguments as root, i.e. with sudo if
# available/necessary. Generate an error if not possible.
as_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  elif check_command sudo; then
    verbose "Running elevated command: %s" "$*"
    sudo "$@"
  else
    error "This script requires root privileges"
  fi
}

# Download the url passed as the first argument to the destination path passed
# as a second argument. The destination will be the same as the basename of the
# URL, in the current directory, if omitted.
download() {
  verbose "Downloading $1 to ${2:-$(basename "$1")}"
  if command -v curl >/dev/null; then
    curl -sSL -o "${2:-$(basename "$1")}" "$1"
  elif command -v wget >/dev/null; then
    wget -q -O "${2:-$(basename "$1")}" "$1"
  else
    error "You need curl or wget installed to download files!"
  fi
}

install_binary() {
  _bin=$(mktemp)
  download "$1" "$_bin"
  chmod +x "$_bin"
  as_root mv -f "$_bin" "${3:-"/usr/local/bin"}/${2:-$(basename "$1")}"
}

github_releases() {
  download "${INSTALL_GITHUB%%/}/${1}/releases" - |
    grep -oE "${1}/releases/tag/v?[0-9]+\.[0-9]+\.[0-9]+" |
    grep -oE "[0-9]+\.[0-9]+\.[0-9]+" |
    sed '/-/!{s/$/_/}' |
    sort -Vr |
    sed 's/_$//'
}

install_cloudflared() {
  latest=$(github_releases "$INSTALL_CLOUDFLARED" | head -n 1)
  if [ -z "$latest" ]; then
    error "Could not find a release of cloudflared"
  fi
  arch=
  case "$(uname -m)" in
    "x86_64")   arch=amd64;;
    "i686")     arch=386;;
    "aarch64")  arch=arm64;;
    "armv7l")   arch=arm;;
  esac
  if [ -z "$arch" ]; then
    error "Unsupported architecture: %s" "$(uname -m)"
  fi
  url=${INSTALL_GITHUB%%/}/${INSTALL_CLOUDFLARED%//}/releases/download/${latest}/cloudflared-$(uname -s|to_lower)-${arch}
  install_binary "$url" cloudflared
}


if ! check_command cloudflared; then
  install_cloudflared
fi

if ! check_command "$INSTALL_SCRIPT"; then
  install_binary "${INSTALL_GITHUB%%/}/${INSTALL_PROJECT%//}/raw/${INSTALL_BRANCH}/$INSTALL_SCRIPT" "cf-sshd.sh"
fi

if is_true "$INSTALL_RUN"; then
  verbose "Running cf-sshd.sh"
  exec cf-sshd.sh "$@"
fi
