#!/bin/sh

# Set good defaults to allow script to be run by hand. The three variables below
# will be overriden when run from within the workflow.
DOCKER_REPO=${DOCKER_REPO:-"efrecon/cloudflared"}
SOURCE_COMMIT=${SOURCE_COMMIT:-$(git log --no-decorate|grep '^commit'|head -n 1| awk '{print $2}')}
PLATFORMS=${PLATFORMS:-"linux/amd64"}

# Minimum version of cloudflared to build for.
MINVER=${MINVER:-2023.1.0}

# You shouldn't really need to have to modify the following variables.
GH_PROJECT=cloudflare/cloudflared
BUILDX_OPERATION=${BUILDX_OPERATION:-"--push"};   # Change to --load to build only.
OCINS="org.opencontainers.image"

# shellcheck disable=SC1091
. "$(dirname "$0")/reg-tags/image_api.sh"

_releases() {
  # Ask GH for the list of releases matching the tag pattern, then fool the sort
  # -V option to properly understand semantic versioning. Arrange for latest
  # version to be at the top. See: https://stackoverflow.com/a/40391207
  github_releases -r 'v?[0-9]+\.[0-9]+\.[0-9]+' "$1" |
    sed '/-/!{s/$/_/}' |
    sort -Vr |
    sed 's/_$//'
}


# Returns the number of seconds since the epoch for the ISO8601 date passed as
# an argument. This will only recognise a subset of the standard, i.e. dates
# with milliseconds, microseconds, nanoseconds or none specified, and timezone
# only specified as diffs from UTC, e.g. 2019-09-09T08:40:39.505-07:00 or
# 2019-09-09T08:40:39.505214+00:00. The special Z timezone (i.e. UTC) is also
# recognised.
_iso8601() {
    # Arrange for tzdiff to be the number of seconds for the timezone.
    tz=$(printf %s\\n "$1"|sed -E 's/([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.([0-9]{3,9}))?([+-]([0-9]{2}):([0-9]{2})|Z)?/\9/')
    tzdiff=0
    if [ -n "$tz" ]; then
        if [ "$tz" = "Z" ]; then
            tzdiff=0
        else
            hrs=$(printf %s\\n "$tz" | sed -E 's/[+-]([0-9]{2}):([0-9]{2})/\1/')
            mns=$(printf %s\\n "$tz" | sed -E 's/[+-]([0-9]{2}):([0-9]{2})/\2/')
            hrs=${hrs##0}; mns=${mns##0};   # Strip leading 0s
            sign=$(printf %s\\n "$tz" | sed -E 's/([+-])([0-9]{2}):([0-9]{2})/\1/')
            secs=$((hrs*3600+mns*60))
            if [ "$sign" = "-" ]; then
                tzdiff=$secs
            else
                tzdiff=$((-secs))
            fi
        fi
    fi

    # Extract UTC date and time into something that date can understand, then
    # add the number of seconds representing the timezone.
    utc=$(printf %s\\n "$1"|sed -E 's/([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.([0-9]{3,9}))?([+-]([0-9]{2}):([0-9]{2})|Z)?/\1-\2-\3 \4:\5:\6/')
    if [ "$(uname -s)" = "Darwin" ]; then
        secs=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$utc" +"%s")
    else
        secs=$(date -u -d "$utc" +"%s")
    fi
    # shellcheck disable=SC2003 # antiquated but we want parenthesis for clarity
    expr "$secs" + \( "$tzdiff" \)
}


# Return the UNIX timestamp of the docker image passed as argument. This
# downloads the image in all cases.
_docker_timestamp() {
  # Remember if image was already present.
  _present=0
  if docker image inspect "$1" >/dev/null 2>&1; then
    _present=1
  fi

  # Pull image in all cases, we want to have the latest known pushed image for
  # that tag.
  docker image pull --quiet "$1" >/dev/null || true

  # Compute and print the timestamp of the image. 0 if the image does not exist.
  _iso_date=$(docker image inspect --format '{{.Created}}' "$1")
  if [ -z "$_iso_date" ]; then
    printf %d\\n '0'
  else
    _iso8601 "$_iso_date"
  fi

  # Remove the image if it was not present before.
  if [ "$_present" = "0" ]; then
    docker image rm "$1" >/dev/null 2>&1
  fi
}


# Return the UNIX timestamp of the commit reference(s) passed as argument.
_git_timestamp() { git show -s --format="%ct" "$@";}


echo "============== Gettings latest releases for $GH_PROJECT at github"
_latest=
for tag in $(_releases "$GH_PROJECT"); do
  # Latest is the first tag that we encounter.
  if [ -z "$_latest" ]; then
    _latest="$tag"
  fi

  if [ "$(img_version "${tag#v}")" -ge "$(img_version "$MINVER")" ]; then
    img_date=$(_docker_timestamp "${DOCKER_REPO}:$tag")
    git_date=$(_git_timestamp "$SOURCE_COMMIT")
    if [ "$git_date" -ge "$img_date" ]; then
      echo "============== Image ${DOCKER_REPO}:$tag older than $SOURCE_COMMIT"
      # Prepare arguments for docker buildx.
      set -- \
        --tag "${DOCKER_REPO}:$tag" \
        --platform "$PLATFORMS" \
        --build-arg CSHARPIER_VERSION="$tag" \
        --label "${OCINS}.revision=$SOURCE_COMMIT" \
        "$BUILDX_OPERATION"
      # Add latest tag when relevant
      if [ "$tag" = "$_latest" ]; then
        set -- \
          --tag "${DOCKER_REPO}:latest" \
          "$@"
      fi
      if [ -n "$LABEL_AUTHOR" ]; then set -- --label "${OCINS}.authors=$LABEL_AUTHOR" "$@"; fi
      if [ -n "$LABEL_DESCRIPTION" ]; then set -- --label "${OCINS}.description=$LABEL_DESCRIPTION" "$@"; fi
      if [ -n "$LABEL_URL" ]; then set -- --label "${OCINS}.url=$LABEL_URL" "$@"; fi
      if [ -n "$LABEL_TITLE" ]; then set -- --label "${OCINS}.title=$LABEL_TITLE" "$@"; fi
      # Fix dotnet version, migrate to LTS 8.0 starting from 0.26.2. See:
      # https://github.com/belav/cloudflared/releases/tag/0.26.2
      if [ "$(img_version "${tag#v}")" -ge "$(img_version "0.26.2")" ]; then
        set -- \
          --build-arg DOTNET_VERSION="8.0" \
          "$@"
      fi
      # build (and push) according to arguments and at the right tags.
      docker buildx build "$@" .
    else
      echo "!!!!!!!!!!!!!! Image ${DOCKER_REPO}:$tag newer than ${SOURCE_COMMIT}, skipping"
    fi
  fi
done