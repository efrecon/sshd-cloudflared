# Dockerised SSHd Tunnelled through cloudflared

This project aims at providing access to the current directory on your work
machine through an SSH [tunnel] at the CloudFlare edge, all this inside a Docker
container for clean separation of resources. You can also use this project to
[debug](#github-actions-debugging) your GitHub workflows.

Containers are launched in the background and compatible with the vscode
[remote] extension. Traffic is fully encrypted end-to-end. Provided that you
have [installed](#installing-the-wrapper) the [wrapper](#wrapper) `cf-sshd.sh`
and made it available under your `$PATH`, running it will create a background
container and print out instructions for how to connect to it from another
machine using `ssh`:

```console
emmanuel@localhost:~/dev> cf-sshd.sh -v
[cf-sshd.sh] [NFO] [20220916-120406] Pulling latest image ghcr.io/efrecon/sshd-cloudflared:latest
[cf-sshd.sh] [WRN] [20220916-120413] Could not match 'eXXXXn@gmail.com' to user at GitHub
[cf-sshd.sh] [NFO] [20220916-120414] Matched 'Emmanuel Frecon' to 'efrecon' at GitHub
[cf-sshd.sh] [NFO] [20220916-120414] Will get SSH keys for GitHub user efrecon
[cf-sshd.sh] [WRN] [20220916-120414] Removing group write permissions from current directory for proper SSH access!
[cf-sshd.sh] [NFO] [20220916-120415] Waiting for tunnel establishment...
[cf-sshd.sh] [NFO] [20220916-120420] Running in container f105c67100d58a5351818bda3b2468e9902e94fb2642456178027e4f3add4deb


Run the following command to connect:
    ssh-keygen -R dev && echo 'dev ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDGz7HHHQv7TKXEs12NzjpclrhDveqzI5QOmifO97NWBgugymyC75TlyCZ2DCi30jp56ykazoyf+MxffmXuAH5NQSvogmW4mXqzWZzF2Q+pxC5l2qv8+Ag+/0j/bThSMqqCsfNdFEkU61sxR5PPF5feoKTSCLA+7YCCAVtYAgWzce1AoIxCQF8v2f49tZReufDWdpFIpd7OcV/QYaj5qyWVTWe/nu0ztYUiuJlRQwS02yIhcPk/TrEUxE0ImmwvzCI3iAZTp9ORnDcgjKfoeI6xjcqXbCLMw5mt20GchC9AgkzKu2rgG+gOHPC6cjpogJnIxPwPHxdB3se13dLY/mXYqHepY2hicwzkoX3MdrGjC22ti0r+yB+38W6mnRHl7QUhKhtqB04pqooOPwA2ytt9vnj0apVGl89s9XNAM6IRp5NmDJV0YaD4mYMy7cyBr9qNGdfhSmyWHVpgUWlqhBNR0QITV2avit0nuKt0uHY2jBRkqXlY3FvvlFd8n2VV7DdgdsXt3j00yl8zlIUTrEcXc8p2l30etLQ+dHeqZ/sBjgUtotgVoI9dny7qZioc7d5Q/BG5KkB6sfoR7533Y6FQUNbxv5LtEZ4rVNW3qUeMgGhicGSHOpzdKSzBL8+1sZfCksdVD/iXzrv4p+ha5/JogQx807c31NExjhMGJ+jHaw==' >> ~/.ssh/known_hosts && ssh -o ProxyCommand='cloudflared access tcp --hostname https://dispatch-hopkins-pmc-limitations.trycloudflare.com' emmanuel@dev

Run the following command to connect without verification (DANGER!):
    ssh -o ProxyCommand='cloudflared access tcp --hostname https://dispatch-hopkins-pmc-limitations.trycloudflare.com' -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new emmanuel@dev
```

You can then run one of the `ssh` commands printed out on the console to access
your directory. Remember that establishing a tunnel might take a few seconds,
seconds under which `ssh` access will not work. Once logged in, your prompt
should reflect a hostname that is called after the name of the directory where
you created the container. This is to make it easier to differentiate between
several such environments. Inside the container, you will have the same username
as outside.

The entrypoint of the Dockerfile configures and creates a userspace SSH daemon,
and establishes a guest tunnel using [cloudflared]. The SSH daemon automatically
picks authorised keys from any user (yours!) at github, thus restricting access
to that user only.

  [tunnel]: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/do-more-with-tunnels/trycloudflare/
  [cloudflared]: https://github.com/cloudflare/cloudflared
  [remote]: https://code.visualstudio.com/docs/remote/ssh

## GitHub Actions Debugging

To debug a workflow, add a step similar to the following:

```yaml
  - name: SSHd
    id: debug
    uses: efrecon/sshd-cloudflared@main
```

This will [install](#installing-the-wrapper) all dependencies and run the
[entrypoint](./entrypoint.sh) directly on the runner. To get a prompt into your
container inside the runner, run the command written down in the workflow logs.
Breakdown of the options is as follows:

+ `-i` tells the installer to download and install the
  [entrypoint](./entrypoint.sh), instead of the [wrapper](#wrapper).
+ `-r` is sent to the [`install.sh`](,/install.sh) script and tells it to run
  the entrypoint once it has been downloaded.
+ `--` signals the end of options passed to the wrapper, everything else is sent
  to the [`entrypoint`](./entrypoint.sh) of the Docker image.
+ `-g` passes the name of the GitHub user that started the workflow, access to
  the SSH daemon will only be allowed from these keys.

## Tunnelled SSHd

If you do not wish to download or run the [wrapper](#wrapper), you can instead
run the following command.

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
copy of `cloudflared` accessible under the `$PATH`). The command will be output
in the logs, albeit with another access URL and another username:

```shell
ssh \
  -o ProxyCommand='cloudflared access tcp --hostname https://owen-go-exciting-glasgow.trycloudflare.com' \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=accept-new \
  emmanuel@sshd-cloudflared
```

## VS Code

The [`Dockerfile`](./Dockerfile) adds just enough packages to make development
environments created using this image to be used with the [remote] extension of
VS code. You will have to create a Docker volume that will be used to store the
code for the `vscode-server` in the container. The content of this volume needs
to be owned by your user.

To create and initialise the volume, run the following (and possibly adapt):

```shell
docker volume create vscode-server
docker run --rm -v vscode-server:/vscode-server busybox \
  /bin/sh -c "touch /vscode-server/.initialised && chown -R $(id -u):$(id -g) /vscode-server"
```

Once you have created the volume, you can pass it to overload the
`.vscode-server` directory whenever you want an environment, as in the following
command. The first time you start the remote extension against the SSH daemon in
that container, it will install and automatically run the server inside the
`${HOME}/.vscode-server`.

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
2. Arrange for the current directory to only be writable by your user, this is a
   **mandatory** requirement for being able to setup and run a userspace SSH
   daemon in the current directory.
3. Setup a Docker volume unique for your local user, in order to facilitate
   using that container as a VS Code [remote](#vs-code).
4. When called without arguments, the wrapper will collect your `git` email and
   name and try using them to look for your GitHub handle using the [search]
   API.
5. Start a Docker container in the background with either the GitHub handle
   discovered above, or the remaining arguments, as is.
   + Unless specified otherwise, the hostname of the SSH daemon will be the name
     of the directory where the wrapper was started from. This is to better
     identify various development environments.
   + Unless impossible or configured otherwise the wrapper will arrange for the
     `docker` client to be accessible and fully working from within the
     container, thus providing access to the local `docker` daemon.
   + The wrapper should carry on your current shell into the container, as long
     as the container has its binary, e.g. `/bin/bash`.
   + Unless configured otherwise, the wrapper will arrange for the SSH server to
     be compatible with the VS Code Remote extension.
6. Wait for the container and tunnel to be ready and extract tunnel information
   from the Docker logs.

Provided you have the [XDG] directory `$HOME/.local/bin` in your account, run
the following to install the wrapper and make it available as `cf-sshd.sh` under
the `$PATH`.

```shell
curl \
  --location \
  --silent \
  --output "$HOME/.local/bin/cf-sshd.sh" \
  https://raw.githubusercontent.com/efrecon/sshd-cloudflared/main/cf-sshd.sh && \
  chmod u+x "$HOME/.local/bin/cf-sshd.sh"
```

When searching for user details at GitHub fails, you will have to provide this
information at the command-line. The wrapper uses a `--` to separate options
from arguments and all arguments are blindly passed to the entrypoint of the
Docker container. As an example, the following would kickstart a container for
the `efrecon` GitHub user.

```shell
cf-sshd.sh -- -g efrecon
```

The wrapper is designed to minimise input and should "just work". Options and
flags exist to tweak its behaviour to your needs if necessary. Calling it with
the `-h` flag will print help over the dash-led options and flags that it
supports, as well as the environment variables that it recognises.

  [XDG]: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
  [search]: https://docs.github.com/en/search-github/searching-on-github/searching-users

## Installing the Wrapper

An installer script is provided to install the wrapper and cloudflared. To
install them, run the following. The current implementation requires `sudo`
privileges and will install in `/usr/local/bin`. To download, you can use `wget`
instead, as the [installer](./install.sh) supports both `curl` and `wget`.

```bash
curl -sSL https://github.com/efrecon/sshd-cloudflared/raw/main/install.sh | sh -s --
```

## Manual Cleanup

By default, the Docker entrypoint, will create a hidden temporary directory
under the current directory. This directory starts with the `.cf-sshd_` prefix,
followed by a random string. This directory will contain files for the
configuration of the SSH daemon, which need to be accessible with proper
permissions. If you kill the container abruptly (i.e. using `rm -fv` rather than
first running `stop`), the directory will not be removed and you will have to
cleanup manually.

## Similar Work

Part of this code is inspired by [this] project.

  [this]: https://github.com/valeriangalliat/action-sshd-cloudflared

## Development Notes

To work on modifying this implementation, you will have to iteratively (re)build
the images and use the local image for your tests.

### Build Docker Images

To build the docker images locally, run the following commands from this
directory.

```shell
docker build -t ghcr.io/efrecon/sshd-cloudflared-base:latest -f Dockerfile.base .
docker build -t ghcr.io/efrecon/sshd-cloudflared:latest -f Dockerfile .
```

Take a note of the identifier of the last image that was built, e.g.
`552379793d65`

### Run a Container

Use the identifier of the last image built to run a container using the wrapper,
e.g. as in the following command. The command also increases verbosity with the
`-v` option, and exports the port of the SSH daemon locally to the host, at
`2222`.

```shell
./cf-sshd.sh -i 552379793d65 -v -p 2222
```

### Login

You should now be able to login into the container either through the
instructions printed at the terminal, or directly via the exported port, e.g.
with the following command, and provided that your local ssh client is setup
with one of the keys at GitHub.

```shell
ssh localhost -p 2222
```

### Problems?

When looking for problems, look for the Docker container that was created in the
background, its logs will contain the logs from the entrypoint and also from all
underlying services.

Files that were automatically generated are generated in the directory which
name is prefixed with `.cf-sshd_` under the current directory.

### Dismantling

Once done, remove the container in two steps, using the name that was
automatically assigned to it by Docker, e.g. as with the following command. This
gives the container a chance to remove the local directory that it created under
the directory that was shared.

```shell
docker stop practical_agnesi && docker rm -v practical_agnesi
```
