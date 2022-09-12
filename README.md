# Dockerised SSHd Tunnelled through cloudflared

This project aims at providing access to the current directory on your work
machine through an SSH [tunnel] at the CloudFlare edge. The projects configures
and creates a userspace SSH daemon, and establishes a guest tunnel using
[cloudflared]. The SSH daemon automatically picks authorised keys from any user
at github, thus restricting access to that user only. Traffic is fully encrypted
end-to-end.

  [tunnel]: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/do-more-with-tunnels/trycloudflare/
  [cloudflared]: https://github.com/cloudflare/cloudflared

To start a tunnelled SSH server in the current directory, run the following
command. This command documents the internals, there is a better
[way](#wrapper). Jump directly [there](#wrapper) if you just want to get going!

```shell
docker run \
  -d \
  --user "$(id -u):$(id -g)" \
  -v "$(pwd):$(pwd)" \
  -w "$(pwd)" \
  -v /etc/passwd:/etc/passwd:ro \
  -v /etc/group:/etc/group:ro \
  --group-add "$(getent group docker|cut -d: -f 3)" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(command -v docker)":/usr/bin/docker:ro \
  ghcr.io/efrecon/sshd-cloudflared \
  -g xxxx
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
  arranging for your user to be a member of the `docker` group inside the
  container. This enables operations on the local machine's Docker daemon from
  within the container running this image.
+ `xxxx` should be replaced by your handle at GitHub, e.g. `efrecon`

As the command is started in the background, you will have to pick up login
details from the logs. If you have full trust, you should be able to run a
command similar to the following one from another machine (provided it has a
copy of `cloudflared` accessible under the PATH). The command will be output in
the logs, albeit with another access URL and another username:

```shell
ssh \
  -o ProxyCommand='cloudflared access tcp --hostname https://owen-go-exciting-glasgow.trycloudflare.com' \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=accept-new \
  emmanuel@sshd-cloudflared
```

## VS Code

The [`Dockerfile`](./Dockerfile) adds just enough packages to make development
environments created using this image to be used with the remote extension of VS
code. If you do not mount your home directory entirely, you will have to create
a Docker volume that will be used to store the code for the `vscode-server`. The
content of this volume needs to be owned by your user.

To create and initialise the volume, run the following (and possibly adapt):

```shell
docker volume create vscode-server
docker run --rm -v vscode-server:/vscode-server busybox \
  /bin/sh -c "touch /vscode-server/.initialised && chown -R $(id -u):$(id -g) /vscode-server"
```

Once you have created that volume, you can pass it to overload the
`.vscode-server` directory whenever you want an environment, as in the following
command. The first time you start the remote extension against the SSH daemon in
that container, it will install and automatically run the server inside the
`${HOME}/.vscode-server`, which is owned by your user (inside and outside of the
container).

```shell
docker run \
  -d \
  --user "$(id -u):$(id -g)" \
  -v "$(pwd):$(pwd)" \
  -w "$(pwd)" \
  -v /etc/passwd:/etc/passwd:ro \
  -v /etc/group:/etc/group:ro \
  --group-add "$(getent group docker|cut -d: -f 3)" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(command -v docker)":/usr/bin/docker:ro \
  -v "vscode-server:${HOME}/.vscode-server" \
  ghcr.io/efrecon/sshd-cloudflared \
  -g xxxx
```

This command can be automated using the [wrapper](#wrapper).

## Wrapper

As the raw `docker` commands are bit complex, this projects comes with a
[wrapper](./cf-sshd.sh). This is a standalone shell script, tuned for
installation somewhere in the `$PATH`. The wrapper will:

1. Automatically pull the latest image of this project at the GHCR.
2. Setup a Docker volume unique for your local user, in order to facilitate
   using that container as a VS Code [remote](#vs-code).
3. When called without arguments, the wrapper will collect your `git` email and
   name and try using them to look for your GitHub handle using the [search]
   API.
4. Start a Docker container in the background with either the GitHub handle
   discovered above, or the remaining arguments, as is.
5. Wait for the container and tunnel to be ready and extract tunnel information
   from the Docker logs.

Running it with the `-v` option, provided it is in the `$PATH` should provide
output similar to the following:

```console
emmanuel@localhost:~/dev/projects/foss/efrecon/sshd-cloudflared> ./cf-sshd.sh -v
[cf-sshd.sh] [NFO] [20220912-100912] Creating Docker volume vscode-server-emmanuel to store VS Code server
[cf-sshd.sh] [NFO] [20220912-100914] Pulling latest image ghcr.io/efrecon/sshd-cloudflared:latest
[cf-sshd.sh] [WRN] [20220912-100919] Could not match 'efrecon@XXXXXXXXXX' to user at GitHub
[cf-sshd.sh] [NFO] [20220912-100919] Matched 'Emmanuel Frecon' to 'efrecon' at GitHub
[cf-sshd.sh] [NFO] [20220912-100919] Will get SSH keys for GitHub user efrecon
[cf-sshd.sh] [NFO] [20220912-100920] Waiting for tunnel establishment...
[cf-sshd.sh] [NFO] [20220912-100926] Running in container 0588896c2a0ea5d034e590b019002e375113d8664fdf7dd857aee5c213d2f697


Run the following command to connect:
    ssh-keygen -R sshd-cloudflared && echo 'sshd-cloudflared ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCndeSVJpQ13ZRjoZrMLN7oaUh6D/rWBorWiG/jLERGEHHYFJDVR2t8G2GYAAfp8ESECMgrpv3hHBG/0vBtxj0klSDc4+tDpAOt8qnB+rJ6Huh8Z61I1Pxrg5gc1gtSH5dROan8ys5K+KaITn0UbZI+M5dZ5qdRgCC8Tzk0ofzsYNot7O6Ad/b/7jVFoejyOZs2XpnI2Bke3b9kUo9C1QhdRHc7gorxtl2QK22xm4VUJrWF4Q4hFu3lz20y9vscLGdYE/YytstZo+c9wWH3fdAJNmgVOhFczAJhavQIitBhR8dEdWsGV9jSpAUjFHfn4wbbnALI4ORB4oTlT4oA/LTKt6RU09k+IoGFUM5aBVMPNkL0SmaQf1plPfuoi0edAc6BDSW9rIiBQiRExrFlFukMsRop8yCtJNXYrYp0SW/DDYeNDkqP3xDHFO0KowTXlDTkG9RwDGtZn9vE4NbBFx1TB2dsoRtOsW9g8AZdAN+4lNIxGELNrO77s5g+rmT6gCPv9oh0v64mTfB2k8C54Pa6vd4Ys+CHZ1AW65cAQOePvzQpY9g2cvNwQg5+e1X8F1/A0Cd8BCg2edFf8vnl2jcTgdgrfy1c/zaqh3pBQ3zg8e1iHAcWlSI2nXm1GZ3JIJ9+OHNf/kJKI5ZIfs32/JvW9JTPlHhLqrS11Q7bKIZsxQ==' >> ~/.ssh/known_hosts && ssh -o ProxyCommand='cloudflared access tcp --hostname https://involve-upgrades-remember-indicated.trycloudflare.com' emmanuel@sshd-cloudflared

Run the following command to connect without verification (DANGER!):
    ssh -o ProxyCommand='cloudflared access tcp --hostname https://involve-upgrades-remember-indicated.trycloudflare.com' emmanuel@sshd-cloudflared -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new


```

When searching for user details at GitHub fails, you will have to provide this
information at the command-line. The wrapper uses a `--` to separate option from
arguments and all arguments are blindly passed to the entrypoint of the Docker
container. As an example, the following would kickstart a container for the
`efrecon` GitHub user.

```shell
./cf-sshd.sh -- -g efrecon
```

  [search]: https://docs.github.com/en/search-github/searching-on-github/searching-users

## Cleanup

The Docker entrypoint, by default, will create a hidden temporary directory
under the current directory. This directory starts with the `.cf-sshd_` prefix,
followed by a random string. This directory will contain files for the
configuration of the SSH daemon, which need to be accessible with proper
permissions. If you kill the container abruptly (i.e. using `rm -fv` rather than
first running `stop`), the directory will not be removed and you will have to
cleanup manually.
## Similar Work

Part of this code is inspired by [this] project.

  [this]: https://github.com/valeriangalliat/action-sshd-cloudflared

