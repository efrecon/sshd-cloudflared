ARG BASEIMAGE="ghcr.io/efrecon/sshd-cloudflared-base:latest"
FROM ${BASEIMAGE}

# Root for GitHub, hardly likely to change for a long while...
ARG GITHUB_ROOT=https://github.com

# Metadata
LABEL MAINTAINER=efrecon+github@gmail.com
LABEL org.opencontainers.image.title="sshd-cloudflared"
LABEL org.opencontainers.image.description="Development environment using a user-level SSHd tunnelled through cloudflare"
LABEL org.opencontainers.image.authors="Emmanuel Frécon <efrecon+github@gmail.com>"
LABEL org.opencontainers.image.url="$GITHUB_ROOT/efrecon/sshd-cloudflared"
LABEL org.opencontainers.image.documentation="$GITHUB_ROOT/efrecon/sshd-cloudflared/README.md"
LABEL org.opencontainers.image.source="$GITHUB_ROOT/efrecon/sshd-cloudflared"


# gcompat facilitates running glibc binaries and is necessary for mounting the
# local docker client binary into the container. libstdc++, libgcc enable
# running the VS Code Remote Extension against this container. git is also for
# VS Code.
RUN apk add --no-cache gcompat libstdc++ libgcc git
