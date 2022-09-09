FROM alpine
ARG CLOUDFLARED_VERSION=2022.9.0

RUN apk add --no-cache openssh curl jq bash && \
  curl --location --silent --output /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64" && \
  chmod a+x /usr/local/bin/cloudflared

ADD sshd_config.tpl /usr/local/lib/
ADD cf-sshd.sh /usr/local/bin/

ENTRYPOINT [ "/usr/local/bin/cf-sshd.sh" ]
