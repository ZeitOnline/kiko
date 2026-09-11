# [Claude Code](https://code.claude.com/) + [Apple Container](https://github.com/apple/container) sandbox

This setup runs Claude Code inside Apple's `container` runtime, so that
the agent can only see the project directory it was started in — not the
rest of the host's home directory.

The intended boundary is:

    macOS
      |
      +-- $PWD ---------------------- RW --> /workspace
      |
      +-- ~/.claude ----------------- RW --> /home/kiko/.claude
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

    container build -t kiko

This builds the image `kiko:latest`.

## 3. Run

From the project directory that Claude should work in:

    /path/to/this/repo/run.sh

Claude starts with:

    /workspace       = the current working directory
    ~/.claude        = the host's ~/.claude

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

## 5. What is in the image

Base is `ubuntu:26.04` with a non-root user `kiko`:

  - `curl`, `git`, `jq`, `ripgrep`
  - `uv` and Python 3.14
  - `uv`-installed tools: `lefthook`, `ruff`, `tox`, `yq`
  - Claude Code, installed via `https://claude.ai/install.sh`

`~/.claude.json` is symlinked to `~/.claude/claude.json` so that this
file also lives in the host-mounted configuration directory instead of
in the container's home. This way the initial setup only needs to be
run once.

## 6. Container settings

`run.sh` runs the container with:

  - `--cap-drop ALL` — no Linux capabilities
  - `--dns 1.1.1.1` — fixed resolver, independent of host DNS
  - `--init` — proper PID 1 for signal handling and reaping
  - `--rm` — no container state kept between runs
  - `--interactive --tty` — interactive Claude session
  - two bind mounts by default: the workspace and `~/.claude`, plus
    any directory added with `--dir` (see section 4), read-only
    unless `:rw` was requested

## 7. Verify the boundary

Inside the container, these should fail or be absent:

    ls /Users
    ls /Volumes

These should exist:

    ls /workspace
    ls ~/.claude

## 8. Important properties

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

## 9. Network

This configuration intentionally does not claim to restrict network
egress. Claude Code needs network access to Anthropic, and additional
tools may need it too.

If stronger network isolation is required, add a network policy at the
Apple Container/VM layer rather than assuming filesystem isolation also
restricts networking.
