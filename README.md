# Dockerised SSHd Tunnelled through cloudflared

This project aims at providing access to the current directory on your work
machine through SSH tunnelled by CloudFlare. The projects configures and creates
a userspace SSHd and establishes a guest tunnel using [cloudflared]. The SSH
server automatically picks authorised keys from any user at github, thus
filtering access to the ones that you use. Traffic is fully encrypted
end-to-end.

  [cloudflared]: https://github.com/cloudflare/cloudflared

To start a server in the current directory, run the following command:

```shell
docker run \
  -d \
  --user $(id -u):$(id -g) \
  -v $(pwd):$(pwd) \
  -w $(pwd) \
  -v /etc/passwd:/etc/passwd:ro \
  -v /etc/group:/etc/group:ro \
  --group-add $(getent group docker|cut -d: -f 3) \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker:ro \
  ghcr.io/efrecon/sshd-cloudflared \
  -v -g xxxx
```

This command works as follows:

+ It passes your current directory for access to the container, ensuring that
  you will be able to access the files at that location, and nothing else.
+ It passes your current user details (user and group identifier) to the
  container so that the entrypoint will be able to setup the ssh server with
  proper credentials.
+ It passes the group and password details (in read-only mode!) from the current
  machine, so that the ssh server will be able to refer to your username
  properly and impersonate you. This is because the configuration cannot have
  identifiers, only names.
+ It passes the Docker socket and even `docker` binary client, together with
  arranging your user to be a member of the `docker` group. This enables
  operations on the machine's local Docker daemon from within the container
  running this image.
+ `xxxx` should be replaced by your handle at GitHub, e.g. `efrecon`

As the command is started in the background, you will have to pick up login
details from the logs. If you have full trust, you should be able to run a
command similar to the following one from another machine (provided it has a
copy of `cloudflared` accessible under the PATH). The command will be output in
the logs, albeit with another access URL:

```shell
ssh \
  -o ProxyCommand='cloudflared access tcp --hostname https://owen-go-exciting-glasgow.trycloudflare.com' \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=accept-new \
  emmanuel@sshd-cloudflared
```

## Similar Work

Part of this code is inspired by [this] project.

  [this]: https://github.com/valeriangalliat/action-sshd-cloudflared
