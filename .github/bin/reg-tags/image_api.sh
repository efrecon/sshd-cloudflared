#!/bin/sh

# NOTE: This implementation makes use of the local keyword. While this is not a
# pure POSIX shell construction, it is available in almost all implementations.
# This is a library, the file mererly declares a set of functions for you to
# use.

# We start by mismashing to find WHERE this very file is loaded from and store
# this in the _IMG_SELF variable. We use this to be able to provide help with
# the -h/--help options of the various functions. There is no support for this
# in POSIX shell, so it's a bit of wizardry.
if [ -n "${BASH:-}" ]; then
  # shellcheck disable=SC3028,SC3054 # We know BASH_SOURCE only exists under bash!
  _IMG_SELF="${BASH_SOURCE[0]}"
elif command -v "lsof" >/dev/null 2>&1; then
  # Introspect by asking which file descriptors the current process has opened.
  # This is an evolution of https://unix.stackexchange.com/a/351658 and works as
  # follows:
  # 1. lsof is called to list out open files. lsof will have different
  #    results/outputs depending on the shell used. For example, when using
  #    busybox, there are few built-ins.
  # 2. Remove the \0 to be able to understand the result as text
  # 3. Transform somewhat the output of lsof on "normal" distros/shell to
  #    something that partly resembles lsof on busybox, i.e. file descritor id,
  #    followed by space, followed by file spec.
  # 4. Remove irrelevant stuff, these have a tendency to happen after the file
  #    that we are looking for. This is because the pipe implementing this is
  #    active, so binaries, devices, etc. will be opened when it runs in order
  #    to implement it. So we remove /dev references, pipe: (busybox), and all
  #    references to the binaries used when implementing the pipe itself.
  # 5. Focus on files that have a .sh ending only, i.e. likely this file.
  # 6. Pick the first one
  # 7. The file we are looking for is the last whitespace separated field of the
  #    last line.
  _IMG_SELF=$(lsof -p "$$" -Fn0 2>/dev/null |
                tr -d '\0' |
                sed -E 's/^f([0-9]+)n(.*)/\1 \2/g' |
                grep -vE -e '\s+(/dev|pipe:|socket:)' -e '[a-z/]*/bin/(tr|grep|lsof|tail|sed|awk)' |
                grep ".*\.sh" |
                tail -n 1 |
                awk '{print $NF}')
else
  # Introspect by checking which file descriptors the current process has
  # opened as of under the /proc tree.
  # 1. List opened file descriptors for the current process, sorted by last
  #    access time. Listing is in long format to be able to catch the trailing
  #    -> that will point to the real location of the file.
  # 2. Isolate the symlinking part of the ls -L listing.
  # 3. Remove irrelevant stuff, these have a tendency to happen after the file
  #    that we are looking for. This is because the pipe implementing this is
  #    active, so binaries, devices, etc. will be opened when it runs in order
  #    to implement it. So we remove /dev references, pipe: (busybox), and all
  #    references to the binaries used when implementing the pipe itself.
  # 4. Focus on files that have a .sh ending only, i.e. likely this file.
  # 5. Pick the first one
  # 6. The file we are looking for is the last whitespace separated field of
  #    the last line.

  # shellcheck disable=SC2010 # We believe this is ok in the context of /proc
  _IMG_SELF=$(ls -tul "/proc/$$/fd" 2>/dev/null |
                grep -oE '[0-9]+\s+->\s+.*' |
                grep -vE -e '\s+(/dev|pipe:|socket:)' -e '[a-z/]*/bin/(ls|grep|tail|sed|awk)'|
                grep ".*\.sh" |
                tail -n 1 |
                awk '{print $NF}')
fi

_img_usage() {
    # shellcheck disable=SC2120
    _img_align() {
    # shellcheck disable=SC3043
    local line || true

    while IFS= read -r line; do
        printf "%s%s %s\n" \
        "$(printf "%.${1:-35}s\n" "$(printf "%s\n" "$line"|cut -d "${2:-":"}" -f 1)$(head -c "${1:-35}" < /dev/zero | tr '\0' ' ')")" \
        "${2:-":"}" \
        "$(printf %s\\n "$line"|cut -d "${2:-":"}" -f 2-)"
    done
    }

    sed -E 's/^\s+//g' <<-EOF | fold -s -w 80
        ${2:-}

        Options:
EOF
    grep -E -A 60 -e "^${1}" "$_IMG_SELF" |
        grep -E '\s+-[a-zA-Z-].*)\s+#' |
        sed -E \
            -e 's/^\s+/    /g' \
            -e 's/\)\s+#\s+/:/g' |
        _img_align
    exit "${3:-0}"
}

_img_downloader() {
    if command -v curl >/dev/null; then
        [ "$_verbose" = "1" ] && echo "Using curl for downloads" >&2
        # shellcheck disable=SC2037
        printf %s\\n "curl -sSL"
    elif command -v wget >/dev/null; then
        [ "$_verbose" = "1" ] && echo "Using wget for downloads" >&2
        # shellcheck disable=SC2037
        printf %s\\n "wget -q -O -"
    else
        printf %s\\n ""
    fi
}

# Prints out the entrypoint to authorise for the registry contained from the
# image name passed as an argument. The default is for images to be located at
# the DockerHub, and this function handles the DockerHub itself as the special
# case it is, i.e. authorisation happens at auth.docker.io. This function is
# also able to detect harbor registries, as these have a slightly different
# entrypoint when authorising according to the Docker registry protocol. The
# entrypoint that is returned contains the HTTP scheme to use.
_img_authorizer() {
    # Decide how to download silently
    # shellcheck disable=SC3043
    local download || true
    download="$(_img_downloader)"
    if [ -z "$download" ]; then return 1; fi

    if [ "$#" = "0" ]; then
        return 1
    fi

    # shellcheck disable=SC3043
    local _qualifier _scheme || true
    if printf %s\\n "$1" | grep -qE '^https?://'; then
        _scheme="$(printf %s\\n "$1" | sed -E 's~^(https?):.*~\1~')://"
        _qualifier="$(printf %s\\n "$1" | cut -d / -f 3)"
    else
        _scheme=https://
        _qualifier="$(printf %s\\n "$1" | cut -d / -f 1)"
    fi
    if printf %s\\n "$_qualifier" | grep -qE '^(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+[A-Za-z]{2,6}|localhost)(:[0-9]+)?$'; then
        case "$_qualifier" in
            docker.*)
                printf %s%s\\n "$_scheme" "auth.docker.io";;
            *)
                if $download "${_scheme}${_qualifier}" | grep -qF 'harbor'; then
                    printf %s%s\\n "$_scheme" "${_qualifier}/service"
                else
                    printf %s%s\\n "$_scheme" "${_qualifier}"
                fi
                ;;
        esac
    else
        printf %s%s\\n "$_scheme" "auth.docker.io"
    fi
}

_img_registry() {
    # shellcheck disable=SC3043
    local _qualifier _scheme || true
    if printf %s\\n "$1" | grep -qE '^https?://'; then
        _scheme="$(printf %s\\n "$1" | sed -E 's~^(https?):.*~\1~')://"
        _qualifier="$(printf %s\\n "$1" | cut -d / -f 3)"
    else
        _scheme=https://
        _qualifier="$(printf %s\\n "$1" | cut -d / -f 1)"
    fi
    if printf %s\\n "$_qualifier" | grep -qE '^(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+[A-Za-z]{2,6}|localhost)(:[0-9]+)?$'; then
        case "$_qualifier" in
            docker.*)
                printf %s%s\\n "$_scheme" "registry.docker.io";;
            *)
                printf %s%s\\n "$_scheme" "${_qualifier}";;
        esac
    else
        printf %s%s\\n "$_scheme" "registry.docker.io"
    fi
}

_img_image() {
    # shellcheck disable=SC3043
    local _qualifier _start || true
    if printf %s\\n "$1" | grep -qE '^https?://'; then
        _qualifier="$(printf %s\\n "$1" | cut -d / -f 3)"
        _start=4
    else
        _qualifier="$(printf %s\\n "$1" | cut -d / -f 1)"
        _start=2
    fi
    if printf %s\\n "$_qualifier" | grep -qE '^(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+[A-Za-z]{2,6}|localhost)(:[0-9]+)?$'; then
        printf %s\\n "$1" | cut -d / -f ${_start}-
    elif printf %s\\n "$1" | grep -q '/'; then
        printf %s\\n "$1"
    else
        printf %s\\n "library/$1"
    fi
}

github_releases() {
    # shellcheck disable=SC3043
    local _verbose _api _jq _ver _field || true
    # defaults
    _verbose=0;                     # Be silent by default
    _api=https://api.github.com/;   # GitHub API root
    _jq=jq;                         # Default is to look for jq under the PATH
    _ver='v[0-9]+\.[0-9]+\.[0-9]+'; # How to extract the release number?
    _field='tag_name';              # Which JSON field to extract the release # from
    while [ $# -gt 0 ]; do
        case "$1" in
            -g | --github)    # GitHub API root, default: https://api.github.com/
                _api=$2; shift 2;;
            --github=*)
                _api="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -f | --field)     # JSON field to extract release number from
                _field=$2; shift;;
            --field=*)
                _field="${1#*=}"; shift 1;;

            -r | --release)   # RegEx to extract the release number from field, default: v-led pure SemVer
                _ver=$2; shift 2;;
            --release=*)
                _ver="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            --trace)          # Increase verbosity even more, may reveal secrets
                _verbose=2; shift;;

            -h | --help)      # Print help and return
                _img_usage "github_releases" "Print releases for GitHub project passed as argument";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    # Decide how to download silently
    # shellcheck disable=SC3043
    local download || true
    download="$(_img_downloader)"
    if [ -z "$download" ]; then return 1; fi

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    [ "$_verbose" -ge "1" ] && echo "Getting releases for $1" >&2
    if [ -z "$_jq" ]; then
        $download "${_api%/}/repos/$1/releases" |
            grep -oE '\s*"'"${_field}"'"\s*:\s*"([^"]+)"' |
            sed -E 's/\s*"'"${_field}"'"\s*:\s*"([^"]+)"/\1/' |
            grep -E '^'"$_ver"'$'
    else
        $download "${_api%/}/repos/$1/releases" |
            jq -r ".[].${_field}" |
            grep -E '^'"$_ver"'$'
    fi
}


# Try using the API as in img_labels and as in the ruby implementation
# https://github.com/Jack12816/plankton/blob/58bd9deee339c645d36454a3819d95fcfe34e55d/lib/plankton/monkey_patches.rb#L119
# instead.
img_tags() {
    # shellcheck disable=SC3043
    local _filter _verbose _reg _auth _token _jq || true
    # Defaults
    _filter=".*"; # Print out all tags
    _verbose=0;   # Be silent by default
    _reg=;        # Guess the registry by default
    _auth=;       # Guess where to authorise by default
    _creds=    ; # Credentials (colon separated) for authorisation, empty to get from local config
    _token=;      # Authorisation token, when empty (default) go get it first
    _jq=jq;       # Default is to look for jq under the PATH
    while [ $# -gt 0 ]; do
        case "$1" in
            -f | --filter)    # regex filter to select tags to print out
                _filter=$2; shift 2;;
            --filter=*)
                _filter="${1#*=}"; shift 1;;

            -r | --registry)  # Registry where to find the image, default: empty == guess
                _reg=$2; shift 2;;
            --registry=*)
                _reg="${1#*=}"; shift 1;;

            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            -c | --creds | --credentials) # Credentials when authorising, default: empty == guess from .docker/config.json
                _creds=$2; shift 2;;
            --creds=* | --credentials=*)
                _creds="${1#*=}"; shift 1;;

            -t | --token)     # Authorisation token to use, default: empty == use other options to login first
                _token=$2; shift 2;;
            --token=*)
                _token="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            --trace)          # Increase verbosity even more, may reveal secrets
                _verbose=2; shift;;

            -h | --help)      # Print help and return
                _img_usage "img_tags" "Print tags for image passed as an argument";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    # Decide how to download silently
    # shellcheck disable=SC3043
    local download || true
    download="$(_img_downloader)"
    if [ -z "$download" ]; then return 1; fi

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    # Library images or user/org images?
    # shellcheck disable=SC3043
    local _img || true
    _img="$(_img_image "$1")"
    [ -z "$_reg" ] && _reg=$(_img_registry "$1")
    if [ "${_reg%%/}" = "https://registry.docker.io" ]; then
        _reg=https://registry-1.docker.io
    fi

    # Authorizing at Docker for that image. We need to do this, even for public
    # images.
    if [ -z "$_token" ]; then
        _token=$(   img_auth \
                        --jq "$_jq" \
                        --auth "$_auth" \
                        --creds "$_creds" \
                        --verbose="$_verbose" \
                        -- \
                            "$1")
        [ "$_verbose" -ge "2" ] && echo ">> Auth token: $_token" >&2
    fi

    # Get the list of tags
    [ "$_verbose" -ge "1" ] && echo "Getting tags for ${_img}" >&2
    if [ -z "$_jq" ]; then
        $download \
                --header "Authorization: Bearer $_token" \
                "${_reg%%/}/v2/${_img}/tags/list?n=40" |
            grep -E '.*"tags"[[:space:]]*:[[:space:]]*\[([^]]+)\]' |
            sed -E 's/.*"tags"[[:space:]]*:[[:space:]]*\[([^]]+)\].*/\1/' |
            sed -E 's/"[[:space:]]*,[[:space:]]*/\n/g' |
            sed -E -e 's/^"//g' -e 's/"$//' |
            grep -E "$_filter"
    else
        $download \
                --header "Authorization: Bearer $_token" \
                "${_reg%%/}/v2/${_img}/tags/list" |
            jq -r .tags |
            head -n -1 | tail -n +2 |
            sed -E -e 's/^[[:space:]]*"//g' -e 's/",?$//' |
            grep -E "$_filter"
    fi
}


# Return the base64 encoded credentials to access the image $1, or an empty
# string. This will automatically pick credentials from the config.json file
# under the $DOCKER_CONFIG directory (or its default location when it does not
# exist).
img_credentials() {
    # shellcheck disable=SC3043
    local _verbose _auth _jq _reg || true
    # defaults
    _verbose=0 ; # Be silent by default
    _auth=     ; # Default is to guess where to authorise
    _jq=jq     ; # Default is to look for jq under the PATH
    _reg=      ; # Registry to use
    while [ $# -gt 0 ]; do
        case "$1" in
            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            -h | --help)      # Print help and return
                _img_usage "img_credentials" "Pick registry credentials to access image passed as argument";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    # Return the section of text from $1, between (incl.) the lines containing the
    # literals $2 and $3.
    _between() {
        # shellcheck disable=SC3043
        local _start _stop || true

        _start=$(grep -nFo -m 1 "$2" "$1"|cut -d: -f1)
        if [ -z "$_start" ]; then return; fi
        _stop=$(tail -n +"$_start" "$1" | grep -nFo -m 1 "$3"|cut -d: -f1)
        tail -n +"$_start" "$1" | head -n "$_stop"
    }

    # Decide how to download silently
    # shellcheck disable=SC3043
    local download || true
    download="$(_img_downloader)"
    if [ -z "$download" ]; then return 1; fi

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    # Default authorizer
    [ -z "$_auth" ] && _auth=$(_img_authorizer "$1")
    _reg=$(printf %s\\n "$_auth" | sed -E -e 's~^https?://~~' -e 's~/$~~')
    if [ "$_reg" = "auth.docker.io" ]; then
        _reg="https://index.docker.io/v1/"
    else
        _reg="$(printf %s\\n "$_reg" | cut -d / -f 1)"
    fi
    # Authorizing at Docker for that image, if possible. Arrange to return an
    # empty string, no error when no credentials are provided.
    [ "$_verbose" -ge "1" ] && echo "Looking for credentials for $1 from $_reg" >&2
    if [ -z "$_jq" ]; then
        _between "${DOCKER_CONFIG:-${HOME}/.docker}/config.json" "${_reg}" "}" |
            grep -F '"auth"' |
            sed -E -e 's/.*"auth": "([^"]+)".*/\1/'
    else
        ( $_jq \
            -r ".auths.\"${_reg}\".auth" \
            "${DOCKER_CONFIG:-${HOME}/.docker}/config.json" |
            grep -v null ) || true
    fi
}


img_auth() {
    # shellcheck disable=SC3043
    local _verbose _auth _jq _creds || true
    # Defaults
    _verbose=0 ; # Be silent by default
    _auth=     ; # Default is to guess where to authorise
    _jq=jq     ; # Default is to look for jq under the PATH
    _creds=    ; # Credentials (colon separated) for authorisation, empty to get from local config
    while [ $# -gt 0 ]; do
        case "$1" in
            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -c | --creds | --credentials) # Credentials when authorising, default: empty == guess from .docker/config.json
                _creds=$2; shift 2;;
            --creds=* | --credentials=*)
                _creds="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            -h | --help)      # Print help and return
                _img_usage "img_auth" "Print authorisation token to access image passed as a parameter";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    # Does the value passed as a parameter contain only characters used in
    # base64 encoding.
    _base64encoded() {
        test -z "$(printf %s\\n "$1" | tr -d '[A-Za-z0-9/=\n')"
    }

    # Decide how to download silently
    # shellcheck disable=SC3043
    local download || true
    download="$(_img_downloader)"
    if [ -z "$download" ]; then return 1; fi

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    # Library images or user/org images?
    # shellcheck disable=SC3043
    local _img || true
    _img="$(_img_image "$1")"

    # Default authorizer
    [ -z "$_auth" ] && _auth=$(_img_authorizer "$1")

    # Get credentials for access to the registry, if possible, in base64 encoded
    # form
    if [ -z "$_creds" ]; then
        if [ "$_verbose" -ge "1" ]; then
            _creds=$(img_credentials --auth "$_auth" --jq "$_jq" --verbose -- "$_img")
        else
            _creds=$(img_credentials --auth "$_auth" --jq "$_jq" -- "$_img")
        fi
    elif ! _base64encoded "$_creds"; then
        _creds=$(printf %s "$_creds" | base64 -w 0)
    fi
    # shellcheck disable=SC3043
    local _svc || true
    if printf %s\\n "$_auth" | grep -qE '/service.$'; then
        _svc=harbor-registry
    else
        # Remove protocol (HTTP) scheme
        _svc=$(_img_registry "$1"|sed -E 's~^https?://~~')
    fi

    # Authorizing at Docker for that image
    # shellcheck disable=SC3043
    local _authorisation || true
    if [ -n "$_creds" ]; then
        [ "$_verbose" -ge "1" ] && echo "Authorizing as $(printf %s "$_creds" | base64 -d| cut -d: -f1) for $_img at $_auth" >&2
        # Manually add a Basic Auth header, as the --header option is supported
        # by both curl and wget
        _authorisation=$($download \
                            --header "Authorization: Basic $_creds" \
                            "${_auth%%/}/token?scope=repository:${_img}:pull&service=${_svc}")
    else
        _authorisation=$($download \
                            "${_auth%%/}/token?scope=repository:${_img}:pull&service=${_svc}")
    fi
    if printf %s\\n "$_authorisation" | grep -q '"token"'; then
        if [ -z "$_jq" ]; then
            printf %s\\n "$_authorisation" |
                grep -E '^\{?[[:space:]]*"token"' |
                sed -E 's/\{?[[:space:]]*"token"[[:space:]]*:[[:space:]]*"([a-zA-Z0-9_.-]+)".*/\1/'
        else
            printf %s\\n "$_authorisation" |
                $_jq -r '.token'
        fi
    fi
    unset _authorisation
}


img_config() {
    # shellcheck disable=SC3043
    local _verbose _reg _auth _jq _token
    # Defaults
    _verbose=0 ; # Be silent by default
    _reg=      ; # Guess the registry by default
    _auth=     ; # Guess where to authorise by default
    _creds=    ; # Credentials (colon separated) for authorisation, empty to get from local config
    _jq=jq     ; # Default is to use jq from the PATH when it exists
    _token=    ; # Authorisation token, when empty (default) go get it first
    while [ $# -gt 0 ]; do
        case "$1" in
            -r | --registry)  # Registry where to find the image, default: empty == guess
                _reg=$2; shift 2;;
            --registry=*)
                _reg="${1#*=}"; shift 1;;

            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            -c | --creds | --credentials) # Credentials when authorising, default: empty == guess from .docker/config.json
                _creds=$2; shift 2;;
            --creds=* | --credentials=*)
                _creds="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -t | --token)     # Authorisation token to use, default: empty == use other options to login first
                _token=$2; shift 2;;
            --token=*)
                _token="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            --trace)          # Increase verbosity even more, may reveal secrets
                _verbose=2; shift;;

            -h | --help)      # Print help and return
                _img_usage "img_config" "Print configuration of image and tag passed as arguments";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    # Decide how to download silently
    # shellcheck disable=SC3043
    local download || true
    download="$(_img_downloader)"
    if [ -z "$download" ]; then return 1; fi

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    # Library images or user/org images?
    # shellcheck disable=SC3043
    local _img || true
    _img="$(_img_image "$1")"
    [ -z "$_reg" ] && _reg=$(_img_registry "$1")
    if [ "${_reg%%/}" = "https://registry.docker.io" ]; then
        _reg=https://registry-1.docker.io
    fi

    # Default to tag called latest when none specified
    # shellcheck disable=SC3043
    local _tag || true
    if [ "$#" -ge "2" ]; then
        _tag=$2
    else
        [ "$_verbose" -ge "1" ] && echo "No tag specified, defaulting to latest" >&2
        _tag=latest
    fi

    # Authorizing at Docker for that image. We need to do this, even for public
    # images.
    if [ -z "$_token" ]; then
        _token=$(   img_auth \
                        --jq "$_jq" \
                        --auth "$_auth" \
                        --creds "$_creds" \
                        --verbose="$_verbose" \
                        -- \
                            "$1")
        [ "$_verbose" -ge "2" ] && echo ">> Auth token: $_token" >&2
    fi

    # Get the digest of the image configuration
    [ "$_verbose" -ge "1" ] && echo "Getting digest for ${_img}:${_tag}" >&2
    if [ -z "$_jq" ]; then
        _digest=$(  $download \
                        --header "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                        --header "Authorization: Bearer $_token" \
                        "${_reg%%/}/v2/${_img}/manifests/$_tag" |
                    grep -E '"digest"' |
                    head -n 1 |
                    sed -E 's/[[:space:]]*"digest"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' )
    else
        _digest=$(  $download \
                        --header "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                        --header "Authorization: Bearer $_token" \
                        "${_reg%%/}/v2/${_img}/manifests/$_tag" |
                    $_jq -r '.config.digest' )
    fi
    [ "$_verbose" -ge "2" ] && echo ">> Digest: $_digest" >&2

    if [ -n "$_digest" ] && [ "$_digest" != "null" ]; then
        # Download the content of the image configuration.
        [ "$_verbose" -ge "1" ] && echo "Getting configuration for ${_img}:${_tag}" >&2
        $download \
                --header "Authorization: Bearer $_token" \
                "${_reg%%/}/v2/${_img}/blobs/$_digest"; return
    fi
}


img_meta() {
    # shellcheck disable=SC3043
    local _verbose _reg _auth _jq _token
    # Defaults
    _verbose=0 ; # Be silent by default
    _reg=      ; # Guess the registry by default
    _auth=     ; # Guess where to authorise by default
    _creds=    ; # Credentials (colon separated) for authorisation, empty to get from local config
    _jq=jq     ; # Default is to use jq from the PATH when it exists
    _token=    ; # Authorisation token, when empty (default) go get it first
    while [ $# -gt 0 ]; do
        case "$1" in
            -r | --registry)  # Registry where to find the image, default: empty == guess
                _reg=$2; shift 2;;
            --registry=*)
                _reg="${1#*=}"; shift 1;;

            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            -c | --creds | --credentials) # Credentials when authorising, default: empty == guess from .docker/config.json
                _creds=$2; shift 2;;
            --creds=* | --credentials=*)
                _creds="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -t | --token)     # Authorisation token to use, default: empty == use other options to login first
                _token=$2; shift 2;;
            --token=*)
                _token="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            --trace)          # Increase verbosity even more, may reveal secrets
                _verbose=2; shift;;

            -h | --help)      # Print help and return
                _img_usage "img_meta" "Print meta information for image and tag passed as 2nd and 3rd arguments. meta (1st argument) can be one of: architecture, os, user, date (or its synonym: created)";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    # shellcheck disable=SC3043
    local _conf _meta || true
    _meta=$1; shift
    _conf=$(    img_config \
                    --verbose=$_verbose \
                    --registry "$_reg" \
                    --auth "$_auth" \
                    --creds "$_creds" \
                    --jq "$_jq" \
                    --token "$_token" \
                    -- \
                        "$@" )

    _json_field() {
        if [ -z "$_jq" ]; then
            if printf %s\\n "$_conf" | grep -qF "\"$1\""; then
                printf %s\\n "$_conf" |
                grep -F "\"$1\"" |
                head -n 1 |
                sed -E "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
            fi
        else
            printf %s\\n "$_conf" |
            $_jq -r "${2:-.$1}"
        fi
    }

    case "$_meta" in
        "created" | "date")
            _json_field "created";;
        "architecture" | "os")
            _json_field "$_meta";;
        "user")
            _json_field "User" ".config.User" ;;
        *)
            echo "$_meta unknown meta information!" >&2; return 1;;
    esac
}


img_labels() {
    # shellcheck disable=SC3043
    local _verbose _reg _auth _jq _pfx _token || true
    # Defaults
    _verbose=0 ; # Be silent by default
    _reg=      ; # Guess the registry by default
    _auth=     ; # Guess where to authorise by default
    _creds=    ; # Credentials (colon separated) for authorisation, empty to get from local config
    _jq=jq     ; # Default is to use jq from the PATH when it exists
    _pfx=      ; # Prefix to add in front of each label name
    _token=    ; # Authorisation token, when empty (default) go get it first
    while [ $# -gt 0 ]; do
        case "$1" in
            -r | --registry)  # Registry where to find the image, default: empty == guess
                _reg=$2; shift 2;;
            --registry=*)
                _reg="${1#*=}"; shift 1;;

            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            -c | --creds | --credentials) # Credentials when authorising, default: empty == guess from .docker/config.json
                _creds=$2; shift 2;;
            --creds=* | --credentials=*)
                _creds="${1#*=}"; shift 1;;

            -p | --prefix)    # Prefix to add in front of each lable name, default: empty
                _pfx=$2; shift 2;;
            --prefix=*)
                _pfx="${1#*=}"; shift 1;;

            -t | --token)     # Authorisation token to use, default: empty == use other options to login first
                _token=$2; shift 2;;
            --token=*)
                _token="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            --trace)          # Increase verbosity even more, may reveal secrets
                _verbose=2; shift;;

            -h | --help)      # Print help and return
                _img_usage "img_labels" "Print labels of image and tag passed as arguments";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    if [ "$#" = "0" ]; then
        return 1
    fi

    # Decide if we can use jq or not
    if ! command -v "$_jq" >/dev/null; then
        [ "$_verbose" -ge "1" ] && echo "jq not found as $_jq, will approximate" >&2
        _jq=
    fi

    # shellcheck disable=SC3043
    local _conf || true
    _conf=$(    img_config \
                    --verbose=$_verbose \
                    --registry "$_reg" \
                    --auth "$_auth" \
                    --creds "$_creds" \
                    --jq "$_jq" \
                    --token "$_token" \
                    -- \
                        "$@" )
    if [ -z "$_jq" ]; then
        # Check if "Labels" is null or empty, if not isolate everything between
        # the opening and end curly brace and look for labels there. This will
        # not work if the label name or content contains curly braces! In the
        # JSON block after "Labels", we remove the leading and ending curly
        # brace and replace "," with quotes with line breaks in between.
        if ! printf %s\\n "$_conf" | grep -qE '"Labels"[[:space:]]*:[[:space:]]*(null|\{\})'; then
            printf %s\\n "$_conf" |
            sed -E 's/.*"Labels"[[:space:]]*:[[:space:]]*(\{[^}]+\}).*/\1/' |
            sed -e 's/^{//' -e 's/}$//' -e 's/","/"\n"/g' |
            sed -E "s/[[:space:]]*\"([^\"]+)\"[[:space:]]*:[[:space:]]*\"(.*)\"\$/${_pfx}\1=\2/g"
        fi
    else
        printf %s\\n "$_conf" |
        $_jq -r '.config.Labels' |
        head -n -1 | tail -n +2 |
        sed -E 's/(.+),$/\1/g' |
        sed -E "s/[[:space:]]*\"([^\"]+)\"[[:space:]]*:[[:space:]]*\"(.*)\"\$/${_pfx}\1=\2/g"
    fi
}


img_newtags() {
    # shellcheck disable=SC3043
    local _flt _verbose _reg _auth _token _jq || true
    # Defaults
    _flt=".*"  ; # Default is all tags.
    _verbose=0 ; # Be silent by default
    _reg=      ; # Guess the registry by default
    _auth=     ; # Guess where to authorise by default
    _creds=    ; # Credentials (colon separated) for authorisation, empty to get from local config
    _token=    ; # Authorisation token, when empty (default) go get it first
    _jq=jq     ; # Default is to look for jq under the PATH
    while [ $# -gt 0 ]; do
        case "$1" in
            -f | --filter)    # regex filter to select tags to print out
                _filter=$2; shift 2;;
            --filter=*)
                _filter="${1#*=}"; shift 1;;

            -r | --registry)  # Registry where to find the image, default: empty == guess
                _reg=$2; shift 2;;
            --registry=*)
                _reg="${1#*=}"; shift 1;;

            -a | --auth)      # Location where to authorise, default: empty == guess
                _auth=$2; shift 2;;
            --auth=*)
                _auth="${1#*=}"; shift 1;;

            -c | --creds | --credentials) # Credentials when authorising, default: empty == guess from .docker/config.json
                _creds=$2; shift 2;;
            --creds=* | --credentials=*)
                _creds="${1#*=}"; shift 1;;

            -t | --token)     # Authorisation token to use, default: empty == use other options to login first
                _token=$2; shift 2;;
            --token=*)
                _token="${1#*=}"; shift 1;;

            --jq)             # Location for jq binary, default: jq (in the path)
                _jq=$2; shift 2;;
            --jq=*)
                _jq="${1#*=}"; shift 1;;

            -v | --verbose)   # Increase verbosity
                _verbose=1; shift;;
            --verbose=*)
                _verbose="${1#*=}"; shift 1;;

            -h | --help)      # Print help and return
                _img_usage "img_newtags" "Print tags difference between images passed as arguments";;

            --)
                shift; break;;
            -*)
                echo "$1 unknown option!" >&2; return 1;;
            *)
                break;
        esac
    done

    [ "$#" -lt "2" ] && return 1

    # shellcheck disable=SC3043
    local _existing || true
    _existing="$(mktemp)"

    [ "$_verbose" = "1" ] && echo "Collecting relevant tags for $2" >&2
    # shellcheck disable=SC2086
    img_tags \
        --verbose=$_verbose \
        --filter "$_flt" \
        --registry "$_reg" \
        --jq "$_jq" \
        --auth "$_auth" \
        --creds "$_creds" \
        --token "$_token" \
        -- \
            "$2" > "$_existing"
    [ "$_verbose" = "1" ] && echo "Diffing against relevant tags for $1" >&2
    # shellcheck disable=SC2086
    img_tags \
        --verbose=$_verbose \
        --filter "$_flt" \
        --registry "$_reg" \
        --jq="$_jq" \
        --auth="$_auth" \
        --creds "$_creds" \
        --token="$_token" \
        -- \
            "$1" |
        grep -F -x -v -f "$_existing"

    rm -f "$_existing"
}

# Remove registry information from an image specification
img_unqualify() {
    printf %s\\n "$1" | sed -E 's~^(https?://)(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+[A-Za-z]{2,6}|localhost)(:[0-9]+)?\/~~'
}

# Return a fully-qualified image name. This will remove the leading scheme
# (non-standard), consider the special case of the docker hub, add "library" and
# the latest tag when necessary.
img_canonicalize() {
    # shellcheck disable=SC3043
    local _image || true
    _image=$(printf %s/%s\\n \
                "$(_img_registry "$1" | sed -E -e 's~^(https?://)~~' -e 's~^registry.docker.io~docker.io~')" \
                "$(_img_image "$1")")
    if ! printf %s\\n "$_image" | grep -qE "@sha256:[0-9a-f]{64}$" \
        && ! printf %s\\n "$_image" | grep -qE ':[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$'; then
        printf "%s:latest\n" "$_image"
    else
        printf %s\\n "$_image"
    fi
}

# From: https://stackoverflow.com/a/37939589
img_version() {
    echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}
