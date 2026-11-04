# [Claude Code](https://code.claude.com/) + [Apple Container](https://github.com/apple/container) sandbox

This setup runs Claude Code inside Apple's `container` runtime, so that
the agent can only see the project directory it was started in — not the
rest of the host's home directory.

The intended boundary is:

    macOS
      |
      +-- $PWD (if allow-listed) -- RW --> /workspace
      |
      +-- ~/.claude -------------- RW --> /home/kiko/.claude
      |
      +-- everything else in $HOME
              |
              +------ NOT MOUNTED

Claude's configuration deliberately stays on the host in `~/.claude`,
so host-side tooling (e.g. [AgentsView](https://www.agentsview.io))
can keep reading sessions, history and settings while the agent
itself runs in the container.

## 1. Install `container`

Apple's `container` needs a Mac with Apple silicon running macOS 26
(Tahoe) or later. Homebrew has it as a regular formula (not a cask):

    brew install container
    brew services start container
    container system kernel set --recommended

`brew services start` runs `container system start
--disable-kernel-install` as a keep-alive launchd service, so the
runtime also comes back after a reboot. Because the service skips the
interactive kernel prompt, the Linux kernel has to be installed
explicitly with the second command. That command talks to the running
API server, so the service must be up *first*; run before it, it fails
with `XPC connection error: Connection invalid`.

Check that the service is up:

    container system status
    container list --all

The second command should print an empty table. Logs go to
`$(brew --prefix)/var/log/container.log`. To shut the runtime down
again, run `brew services stop container`.

Apple itself distributes `container` as a signed installer package from
the [GitHub releases page](https://github.com/apple/container/releases);
use that instead if you prefer not to go through Homebrew.

## 2. Build

From this directory run:

    container build --dns 1.1.1.1 -t kiko

This builds the image `kiko:latest`.

`--dns` matters on the first build: it starts the build VM with a fixed
resolver, the same one `run.sh` uses (see section 9). Without it the
VM asks the host forwarder at `192.168.64.1` over UDP, which some VPN
clients (e.g. Zscaler) swallow; `apt-get update` then times out, exits
0 with an empty index, and the following `apt-get install` fails with
`Unable to locate package`. The flag only applies when `container
build` creates the build VM, so to change it later recreate the VM:

    container builder stop && container builder delete
    container builder start --dns 1.1.1.1

## 3. Run

From the project directory that Claude should work in:

    /path/to/this/repo/run.sh

Claude starts with:

    /workspace       = the current working directory
    ~/.claude        = the host's ~/.claude

The current directory is only mounted if it lies inside one of the
allowed directories (see section 5).

Arguments are passed straight to `claude`, which is the image's
entrypoint:

    ./run.sh --help
    ./run.sh -p 'summarise this repository'

It can be useful to add a shell alias so Claude can be started
as `claude`:

    alias claude "/path/to/this/repo/run.sh"

## 4. Mapping extra directories

Sometimes Claude needs to see more than the current project — sibling
repositories, shared documentation. `run.sh` maps additional host
directories into the workspace with `--dir`:

    ./run.sh --dir ~/work/ops-docs

Each directory shows up as `/workspace/<basename>`, so the example
above becomes `/workspace/ops-docs`. Extra directories are mounted
**read-only** by default; append `:rw` for a writable one:

    ./run.sh --dir ~/work/ops-docs:rw

The option can be repeated and also takes a comma-separated list, and
relative paths stay relative to the directory `run.sh` is started in:

    ./run.sh --dir ../foo --dir ../bar,../scratch

For a fixed set of directories, keep the invocation in a shell alias or
a small wrapper script per project. There is deliberately no config file
that `run.sh` picks up on its own: what Claude can see should always be
visible in the command that started it.

Everything `run.sh` does not recognise is passed through to `claude`
unchanged, so `./run.sh --dir ../foo -p 'compare both repos'` works.
Use `--` if a Claude argument would otherwise be mistaken for one of the
options above, and `./run.sh --sandbox-help` to list them.

Two things to keep in mind:

  - The mount target is derived from the basename, so two directories
    with the same name cannot both be mapped. `run.sh` fails with an
    error instead of silently mounting only one of them.
  - The extra directories appear *inside* `/workspace`, which is the
    project's own git checkout, so `git status` in the container will
    list them as untracked. Adding them to the project's `.gitignore`
    (or `.git/info/exclude`) keeps that quiet.

## 5. Restricting where Claude may be started

Mounting `$PWD` is only safe as long as `$PWD` is a project directory.
Started from `~` — or from `~/Documents`, or `/` — the same command
would hand the whole tree to the agent. To make that mistake loud
instead of silent, `run.sh` checks the current directory against an
allow-list before mounting it:

    KIKO_ALLOWED_DIRS='~/work/'

The variable holds a space-separated list of directories; the current
directory has to be one of them or live below one. The default is
`~/work/`. Widen it in the shell profile if projects live elsewhere:

    export KIKO_ALLOWED_DIRS='~/work/ ~/projects/'

If the current directory is outside all of them, `run.sh` prints a
warning and starts the container *without* mounting it. `/workspace`
is then the empty directory from the image, so Claude comes up with
nothing of the host to look at rather than with the wrong thing:

    run.sh: warning: /Users/me is not inside any of the allowed directories (~/work/)
    run.sh: warning: not mounting it as /workspace; set $KIKO_ALLOWED_DIRS to allow it

The comparison ignores case, because macOS does: having `cd ~/Work`
leave the project unmounted while `cd ~/work` mounts it would be a
puzzle, not a safeguard. The directory is still mounted under the
spelling it was reached by.

Entries that do not exist are ignored, and an empty
`KIKO_ALLOWED_DIRS` allows nothing at all. The check only covers the
current directory — directories added with `--dir` (section 4) are
explicit by nature and are mounted as asked.

## 6. Passing environment variables

The container starts with a clean environment: nothing from the host
shell leaks in, which is the point. Variables that Claude or a tool
inside the container genuinely needs are opted in one at a time, by
exporting them with a `KIKO_ENV_` prefix. `run.sh` passes them on with
the prefix stripped:

    KIKO_ENV_GITHUB_TOKEN=ghp_… ./run.sh

arrives in the container as `GITHUB_TOKEN`. The prefix keeps the
decision explicit: the host variable has a different name than the
one the container sees, so nothing is forwarded just because it
happened to be in the environment.

Values are passed verbatim, including spaces and newlines. A bare
`KIKO_ENV_` (no name after the prefix) is ignored.

## 7. Reaching a VPN on the host

A VPN client on the Mac — Zscaler Client Connector, for instance —
usually does not cover the container. `container` runs its VMs on
macOS's vmnet in NAT mode, and vmnet forwards those packets in the
kernel, past the client's network extension, so they leave on the
plain interface with the Mac's own public address. The symptom is a
container that has working internet but cannot reach anything behind
the VPN.

Check on the Mac which route it takes:

    curl -4 https://api.ipify.org          # the Mac's outgoing address
    route -n get <internal address>        # en0 or utun*?

If the Mac itself goes out via `en0`, the VPN is not routing that
address at all and the container is innocent — fix the split-tunnel
configuration. If the Mac goes out via `utun*` and the container does
not, the client is only handling the Mac's own traffic.

`container` has no option for this: its networking is NAT (plus
host-only), with nothing for VPNs or proxies. There is also a known
bug where vmnet's NAT network is bound to the host's network state at
the time it was created and does not follow a tunnel that comes up
later, which [PR #1666](https://github.com/apple/container/pull/1666)
addresses and [issue #1881](https://github.com/apple/container/issues/1881)
reports as not recovering even after `container system` is restarted.
Connecting the VPN first and then running `container system stop &&
container system start` is worth a minute, but may not stick.

The reliable lever is a proxy on the Mac. The VPN client treats it as
an ordinary local process, so the proxy's own connections do go through
the tunnel:

    brew install tinyproxy
    tinyproxy -d -c <(printf 'Port 3128\nListen 192.168.64.1\nAllow 192.168.64.0/24\n')

It has to listen on the vmnet gateway address (usually
`192.168.64.1`), not on `127.0.0.1` — inside the container, localhost
is the container.

Running it as a service is less typing and survives a reboot. Add one
line to `/opt/homebrew/etc/tinyproxy/tinyproxy.conf`:

    Allow 192.168.0.0/16

then start it:

    brew services restart tinyproxy

The `/16` covers whichever `192.168.6x.0/24` subnet vmnet hands out,
which is not guaranteed to stay the same. The stock configuration
listens on all interfaces, so no `Listen` line is needed — `Allow` is
what keeps it to the local networks. Note the `Port` it sets (8888
unless changed); that is the port to point `run.sh` at.

Point `run.sh` at it with `KIKO_PROXY`:

    KIKO_PROXY=http://192.168.64.1:8888 ./run.sh

That sets `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` inside the
container, in both spellings, since tools disagree about which they
read. `NO_PROXY` defaults to `localhost,127.0.0.1` and can be extended
with `KIKO_NO_PROXY`:

    KIKO_NO_PROXY='localhost,127.0.0.1,.zeit.de' KIKO_PROXY=… ./run.sh

Setting it here rather than in `~/.claude/settings.json` keeps it with
the rest of the sandbox configuration, and covers everything in the
container rather than only Claude Code.

Rather than remembering the address, let the shell look it up —
`container` knows it. A function in `~/.zshrc`:

    claude() {
        local gw port=8888
        gw="$(container network inspect default 2>/dev/null |
              grep -o '"ipv4Gateway"[^,}]*' | head -1 |
              sed -e 's/.*: *"*//' -e 's/[",].*//' -e 's|/.*||')"
        KIKO_PROXY="${gw:+http://$gw:$port}" /path/to/this/repo/run.sh "$@"
    }

With `jq` installed, the three lines of text wrangling collapse into
`jq -r '.[].status.ipv4Gateway'`; the version above keeps the shell
profile free of extra dependencies. The `sed` also strips a `/24`
suffix, should the field ever carry one.

A function rather than an alias, because the lookup has to happen per
call. `${gw:+…}` leaves `KIKO_PROXY` empty if the lookup finds nothing
— the runtime is not up, or that network does not exist — and `run.sh`
ignores an empty value, so the proxy is then simply not configured
instead of being configured wrongly.

### TLS inspection

Zscaler and friends usually inspect TLS, which means the container has
to trust their root CA or every request fails on certificate errors
instead of on a 403. Export the certificate from the Mac's keychain
into a directory, mount it, and point the tools at it:

    ./run.sh --dir ~/work/certs \
      KIKO_ENV_NODE_EXTRA_CA_CERTS=/workspace/certs/zscaler-root.pem

Node — and therefore Claude Code — reads `NODE_EXTRA_CA_CERTS`.
`curl`, `git` and the Python tooling use the system store instead, so
for those the certificate has to be copied to
`/usr/local/share/ca-certificates/` and `update-ca-certificates` run,
which needs to happen in the `Dockerfile` rather than at runtime: the
container user is not root.

## 8. What is in the image

Base is `ubuntu:26.04` with a non-root user `kiko`:

  - `curl`, `git`, `jq`, `ripgrep`
  - `uv` and Python 3.14
  - `uv`-installed tools: `lefthook`, `ruff`, `tox`, `yq`
  - Claude Code, installed via `https://claude.ai/install.sh`

`~/.claude.json` is symlinked to `~/.claude/claude.json` so that this
file also lives in the host-mounted configuration directory instead of
in the container's home. This way the initial setup only needs to be
run once.

## 9. Container settings

`run.sh` runs the container with:

  - `--cap-drop ALL` — no Linux capabilities
  - `--dns 1.1.1.1` — fixed resolver, independent of host DNS
  - `--memory 2G` — memory ceiling for the VM, so a runaway build
    inside the container cannot squeeze the host
  - `--init` — proper PID 1 for signal handling and reaping
  - `--rm` — no container state kept between runs
  - `--interactive --tty` — interactive Claude session
  - `--name <directory>` — named after the directory it was started
    in, so `container ls` tells several sessions apart. The name is
    deliberately not made unique: a second run from the same directory
    is refused by the runtime rather than quietly started alongside
    the first.
  - `--env NAME=…` — one per `KIKO_ENV_NAME` in the host environment
    (see section 6), plus the proxy variables if `KIKO_PROXY` is set
    (see section 7); none by default
  - two bind mounts by default: the workspace (unless the current
    directory failed the check in section 5) and `~/.claude`, plus
    any directory added with `--dir` (see section 4), read-only
    unless `:rw` was requested

## 10. Verify the boundary

Inside the container, these should fail or be absent:

    ls /Users
    ls /Volumes

These should exist:

    ls /workspace
    ls ~/.claude

## 11. Important properties

Do not extend the run command to mount:

    $HOME
    ~/.ssh
    ~/.kube
    ~/.config
    ~/Library

The workspace and `~/.claude` are the only host directories exposed by
default. Directories added with `--dir` widen that boundary
deliberately and one at a time, which is the point: keep them as
narrow as the task needs, and leave them read-only unless Claude
really has to write there. `--dir ~` defeats the whole setup.

Note that `~/.claude` is mounted read-write: this is what makes
host-side session tooling work, but it also means the agent can write to
its own configuration. That is an accepted trade-off here.

There is currently no SSH integration. The container has no access to
host SSH keys or the host `ssh-agent`, so `git` operations against
private remotes will not work from inside the sandbox.

## 12. Network

This configuration intentionally does not claim to restrict network
egress. Claude Code needs network access to Anthropic, and additional
tools may need it too.

If stronger network isolation is required, add a network policy at the
Apple Container/VM layer rather than assuming filesystem isolation also
restricts networking.
