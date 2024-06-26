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

# Name of the development environment to create. This will be used for the name
# of the host to use in the SSH daemon configuration and the hostname within the
# container. This defaults to the name of the current directory, facilitating
# identification in the SSH configuration file and at the terminal prompt once
# you will have ssh'd into the development environment.
CF_SSHD_ENVIRONMENT=${CF_SSHD_ENVIRONMENT:-"$(basename "$(pwd)")"}

# Should the Docker client, if present, be made available inside the container.
CF_SSHD_DOCKER=${CF_SSHD_DOCKER:-1}

# Local port where to make available the SSH daemon. This is mostly for testing
# purposes.
CF_SSHD_PORT=${CF_SSHD_PORT:-""}

# List of directorie/file patterns under the $HOME to mount automatically into
# the container.
CF_SSHD_AUTOMOUNT=${CF_SSHD_AUTOMOUNT:-".cdk* .aws .npm .local .git .docker"}

# Should we wait until container has ended
CF_SSHD_WAIT=${CF_SSHD_WAIT:-0}

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 establishes a cloudflare tunnel and arranges for ssh access to the current directory" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^CF_SSHD_' | sed 's/^CF_SSHD_/    CF_SSHD_/g'
  exit "${1:-0}"
}

while getopts "e:i:l:p:wrvh-" opt; do
  case "$opt" in
    e) # Name of development environment, e.g. name of host in container and SSHd config. Default: directory name
      CF_SSHD_ENVIRONMENT="$OPTARG";;
    l) # Name of volume to mount for VS code support, empty for no support. Default: User-dependent name.
      CF_SSHD_VOLUME="$OPTARG";;
    r) # Do not arrange for Docker client presence inside container
      CF_SSHD_DOCKER=0;;
    i) # Name and tag of the image to use for the container. Default: latest image at the GHCR.
      CF_SSHD_IMAGE="$OPTARG";;
    p) # Local port where to make available the SSH daemon. Default: none
      CF_SSHD_PORT="$OPTARG";;
    w) # Wait until container has ended before exiting
      CF_SSHD_WAIT=1;;
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


if [ "$CF_SSHD_DOCKER" = "1" ]; then
  if [ -z "$(getent group docker)" ]; then
    warn "No group 'docker' on machine => no Docker access from within container!"
    CF_SSHD_DOCKER=0
  fi

  if ! id | grep -Fq "(docker)"; then
    warn "You need to be a member of the group docker for Docker access from within the container"
    CF_SSHD_DOCKER=0
  fi
fi

if [ -n "$CF_SSHD_VOLUME" ]; then
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
fi

if printf %s\\n "$CF_SSHD_IMAGE" | grep -Eq ':latest$'; then
  verbose "Pulling latest image $CF_SSHD_IMAGE"
  docker image pull -q "$CF_SSHD_IMAGE" >/dev/null
fi


# No parameters, try guessing the github username from git settings using the
# GitHub search API.
if [ "$#" = "0" ] && command -v git >/dev/null 2>&1; then
  verbose "No GitHub handle given, will try to guess from git settings"
  handle=;       # Will be the GitHub username, if any
  # Pick user information from gt
  email=$(git config user.email || true)
  fullname=$(git config user.name || true)
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

# Fix permissions and access to current directory with a warning
if ! stat -c %A "$(pwd)"|grep -q '[d-][r-][w-][x-][r-]-[x-][r-][w-][x-]'; then
  warn "Removing group write permissions from current directory for proper SSH access!"
  chmod g-w "$(pwd)"
fi
if ! stat -c %A "$(pwd)"|grep -q '[d-][r-][w-][x-][r-]-[x-][r-]-[x-]'; then
  warn "Removing others write permissions from current directory for proper SSH access!"
  chmod o-w "$(pwd)"
fi

# Create a container arranging for tunneled access to the current directory
# through cloudflare. This recreates the arguments from the end for proper
# quoting.
prefix=$(head -c 16 /dev/urandom | base64 | tr -cd '[:alnum:]' | head -c 16)
# First add Docker image and all command line arguments after the --, if any.
set -- "$CF_SSHD_IMAGE" "$@"
# Add the local volume to store the VS Code server implementation
if [ -n "$CF_SSHD_VOLUME" ]; then
  set -- -v "${CF_SSHD_VOLUME}:${HOME}/.vscode-server" "$@"
fi
# Add the Docker socket, if any, together with the current Docker client binary.
if [ "$CF_SSHD_DOCKER" = "1" ]; then
  set -- \
        --group-add "$(getent group docker|cut -d: -f 3)" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$(command -v docker)":/usr/bin/docker:ro \
        "$@"
fi
# Export the SSH port, if requested to from the command-line
# arguments/environment.
if [ -n "$CF_SSHD_PORT" ]; then
  set -- -p "${CF_SSHD_PORT}:2222" "$@"
fi
# Automatically mount a number of "hidden" files and directory under the home
# directory. This will work as long as the file name do not have line breaks.
newline=$(printf n\\n|tr n \\n);  # Generates a newline
for ptn in $CF_SSHD_AUTOMOUNT; do
  while IFS="$newline" read -r path; do
    if [ -n "$path" ]; then
      verbose "Automounting $path into container"
      set -- -v "${path}:${path}:rw" "$@"
    fi
  done<<EOF
$(find "$HOME" -maxdepth 1 -name "$ptn")
EOF
done
# Add all remaining arguments, i.e. mount as the same user, provide user and
# group database information from the host and pass forward a number of
# environment variables to the entrypoint. The prefix is a random string that
# will be appended to the output lines where to grab the ssh connection
# information.
set -- \
      -d \
      --user "$(id -u):$(id -g)" \
      -v "$(pwd):$(pwd)" \
      -w "$(pwd)" \
      -v /etc/passwd:/etc/passwd:ro \
      -v /etc/group:/etc/group:ro \
      --env "CF_SSHD_PREFIX=$prefix" \
      --env "CF_SSHD_KNOWN_HOST=$CF_SSHD_ENVIRONMENT" \
      --env "CF_SSHD_VERBOSE" \
      --env "SHELL" \
      --hostname "$CF_SSHD_ENVIRONMENT" \
      "$@"
# NOW: start the container in the background
c=$( docker container run "$@" )

# Wait for tunnel information
verbose "Waiting for tunnel establishment..."
while ! docker logs "$c" 2>&1 | grep -qE "^${prefix}"; do sleep 0.25; done

verbose "Running in container $c"
docker logs "$c" 2>&1 | grep -E "^${prefix}" | sed -E "s/^${prefix}//g"

if [ "$CF_SSHD_WAIT" = "1" ]; then
  verbose "Waiting for container to end..."
  docker container wait "$c"
fi
