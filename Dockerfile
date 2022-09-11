ARG ALPINE_VERSION=3.16.2

FROM alpine:${ALPINE_VERSION}

# Root for GitHub, hardly likely to change for a long while...
ARG GITHUB_ROOT=https://github.com

# Build time arguments for where to look for the releases of tini and
# cloudflared and the versions to use.
ARG CLOUDFLARED_DOWNLOAD=${GITHUB_ROOT}/cloudflare/cloudflared/releases/download
ARG CLOUDFLARED_VERSION=2022.9.0
ARG TINI_DOWNLOAD=${GITHUB_ROOT}/krallin/tini/releases/download
ARG TINI_VERSION=v0.19.0
ARG TINI_BIN=tini-muslc-amd64


# Metadata
LABEL MAINTAINER=efrecon+github@gmail.com
LABEL org.opencontainers.image.title="sshd-cloudflared"
LABEL org.opencontainers.image.description="User-level SSHs tunnelled through cloudflare"
LABEL org.opencontainers.image.authors="Emmanuel Frécon <efrecon+github@gmail.com>"
LABEL org.opencontainers.image.url="$GITHUB_ROOT/efrecon/sshd-cloudflared"
LABEL org.opencontainers.image.documentation="$GITHUB_ROOT/efrecon/sshd-cloudflared/README.md"
LABEL org.opencontainers.image.source="$GITHUB_ROOT/efrecon/sshd-cloudflared"


# Install minimal init to place all child processes under our control. This is
# for development environments, so we trust the binary coming from github. We,
# at least, make sure that it is the one that should be there through sha256 sum
# verification.
RUN wget -q ${TINI_DOWNLOAD}/${TINI_VERSION}/${TINI_BIN} \
    && wget -q ${TINI_DOWNLOAD}/${TINI_VERSION}/${TINI_BIN}.sha256sum \
    && echo "$(cat ${TINI_BIN}.sha256sum)" | sha256sum -c \
    && mv ${TINI_BIN} /usr/local/bin/tini \
    && chmod a+x /usr/local/bin/tini \
    && rm -rf ${TINI_BIN}.sha256sum

# Install requirements for the script and the cloudflared binary at the
# requested version. We can now use curl for downloads. Note: we add bash even
# though this isn't required. This is so it can be provided through the `-s`
# option. gcompat facilitates running glibc binaries and is necessary for
# mounting the local docker client binary into the container. libstdc++, libgcc
# enable running the VS Code Remote Extension against this container.
RUN apk add --no-cache openssh curl jq && \
    apk add --no-cache bash gcompat libstdc++ libgcc && \
    curl --location --silent --output /usr/local/bin/cloudflared "${CLOUDFLARED_DOWNLOAD}/$CLOUDFLARED_VERSION/cloudflared-linux-amd64" && \
    chmod a+x /usr/local/bin/cloudflared

COPY sshd_config.tpl /usr/local/lib/
COPY entrypoint.sh /usr/local/bin

# Run behind tini, capturing the entire process group to properly teardown all
# subprocesses.
STOPSIGNAL SIGINT
ENTRYPOINT [ "/usr/local/bin/tini", "-wgv", "--", "/usr/local/bin/entrypoint.sh" ]
