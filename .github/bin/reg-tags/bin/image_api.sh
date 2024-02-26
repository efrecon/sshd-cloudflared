#!/bin/sh

# This calls the functions from the Docker image API library. When named after
# the name of a function (with a trailing `.sh` suffix), and if that function
# exists, the function will be called with all further arguments passed at the
# command-line. Otherwise, the first argument should be the name of an existing
# function of the library (`img_` prefix can be omitted), in which case the
# function will be called with all remaining arguments from the CLI.

# Shell sanity
set -eu

ROOT_DIR=$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )
# shellcheck disable=SC1091
[ -f "${ROOT_DIR}/../image_api.sh" ] && . "${ROOT_DIR}/../image_api.sh"
# shellcheck disable=SC1091
[ -f "${ROOT_DIR}/../lib/image_api.sh" ] && . "${ROOT_DIR}/../lib/image_api.sh"

# Call function with same name as script
SCRIPT=$(basename "$0")

is_function() {
  type "$1" | sed "s/$1//" | grep -qwi function
}

if is_function "${SCRIPT%.*}"; then
  "${SCRIPT%.*}" "$@"
elif is_function "$1"; then
  _fn=$1
  shift
  "$_fn" "$@"
elif is_function "img_$1"; then
  _fn=img_$1
  shift
  "$_fn" "$@"
else
  echo "${SCRIPT%.*} is not implemented" >&2
  exit 1
fi
