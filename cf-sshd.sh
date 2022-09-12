#!/bin/sh

# Failsafe mode: stop on errors and unset vars
set -eu


# Root directory where this script is located
CF_SSHD_ROOTDIR=${CF_SSHD_ROOTDIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}

# Verbosity level
CF_SSHD_VERBOSE=${CF_SSHD_VERBOSE:-"0"}

# URL to Github API
CF_SSHD_API=${CF_SSHD_API:-"https://api.github.com"}

# Docker image to use for the container. When tagged with latest, an attempt to
# pull it will be made in order to catch up with the latest changes.
CF_SSHD_IMAGE=${CF_SSHD_IMAGE:-"ghcr.io/efrecon/sshd-cloudflared:latest"}

# Name of the volume to use for storage of the VS code server
CF_SSHD_VOLUME=${CF_SSHD_VOLUME:-"vscode-server-$USER"}

# Name of the host to use for the SSH daemon configuration and the hostname
# within the container. This defaults to the name of the current directory,
# facilitating identification in the SSH configuration file and at the terminal
# prompt once you will have ssh'd into the container.
CF_SSHD_HOSTNAME=${CF_SSHD_HOSTNAME:-"$(basename "$(pwd)")"}

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

while getopts "n:s:vh-" opt; do
  case "$opt" in
    n) # Name of host to use for container and SSH daemon config
      CF_SSHD_HOSTNAME="$OPTARG";;
    -) # End of options, everything after is passed to the entrypoint of the Docker image.
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


if [ -z "$(getent group docker)" ]; then
  error "No group 'docker' on machine, required"
fi

if ! id | grep -Fq "(docker)"; then
  error "You need to be a member of the group docker to create a container"
fi

if ! docker volume ls --quiet | grep -Fq "$CF_SSHD_VOLUME"; then
  verbose "Creating Docker volume $CF_SSHD_VOLUME to store VS Code server"
  if docker volume create "$CF_SSHD_VOLUME" >/dev/null; then
    docker run \
      --rm \
      -v "${CF_SSHD_VOLUME}:/vscode-server" busybox \
        /bin/sh -c "touch /vscode-server/.initialised && chown -R $(id -u):$(id -g) /vscode-server" >/dev/null 2>&1
  else
    error "Could not create Docker volume"
  fi
fi


if printf %s\\n "$CF_SSHD_IMAGE" | grep -Eq ':latest$'; then
  verbose "Pulling latest image $CF_SSHD_IMAGE"
  docker image pull -q "$CF_SSHD_IMAGE" >/dev/null
fi


# No parameters, try guessing the github username from git settings using the
# GitHub search API.
if [ "$#" = "0" ] && command -v git >/dev/null 2>&1; then
  handle=;       # Will be the GitHub username, if any
  # Pick user information from gt
  email=$(git config user.email)
  fullname=$(git config user.name)
  # Search using the email address, this is often concealed though.
  if [ -n "$email" ]; then
    handle=$( curl --location --silent -G \
                  --data-urlencode "q=$email in:email" \
                "${CF_SSHD_API%/}/search/users" |
              jq -r '.items[0].login' )
    if [ "$handle" = "null" ]; then
      warn "Could not match '$email' to user at GitHub"
      handle=
    else
      verbose "Matched '$email' to '$handle' at GitHub"
    fi
  fi
  # Search using the full name if nothing was found. This is a bit brittle as it
  # is space aware.
  if [ -z "$handle" ] && [ -n "$fullname" ]; then
    handle=$( curl --location --silent -G \
                  --data-urlencode "q=fullname:$fullname" \
                "${CF_SSHD_API%/}/search/users" |
              jq -r '.items[0].login' )
    if [ "$handle" = "null" ]; then
      warn "Could not match '$fullname' to user at GitHub"
      handle=
    else
      verbose "Matched '$fullname' to '$handle' at GitHub"
    fi
  fi

  # When we have a handle, arrange to pass it to the container through CLI args
  # that will become the CMD of the Docker container run command and thus be
  # passed to the entrypoint.
  if [ -z "$handle" ]; then
    error "Cannot find GitHub handle and none given at CLI!"
  else
    verbose "Will get SSH keys for GitHub user $handle"
    set -- -g "$handle"
  fi
fi

# Create a container arranging for tunneled access to the current directory
# through cloudflare.
prefix=$(head -c 16 /dev/urandom | base64 | tr -cd '[:alnum:]' | head -c 16)
c=$(  docker container run \
        -d \
        --user "$(id -u):$(id -g)" \
        -v "$(pwd):$(pwd)" \
        -w "$(pwd)" \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        --group-add "$(getent group docker|cut -d: -f 3)" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$(command -v docker)":/usr/bin/docker:ro \
        -v "${CF_SSHD_VOLUME}:${HOME}/.vscode-server" \
        --env "CF_SSHD_PREFIX=$prefix" \
        --env "CF_SSHD_KNOWN_HOST=$CF_SSHD_HOSTNAME" \
        --hostname "$CF_SSHD_HOSTNAME" \
        "$CF_SSHD_IMAGE" \
        "$@" )

# Wait for tunnel information
verbose "Waiting for tunnel establishment..."
while ! docker logs "$c" 2>&1 | grep -qE "^${prefix}"; do sleep 0.25; done

verbose "Running in container $c"
docker logs "$c" 2>&1 | grep -E "^${prefix}" | sed -E "s/^${prefix}//g"