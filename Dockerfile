FROM ghcr.io/astral-sh/uv:latest AS uv
FROM ubuntu:26.04 AS kiko

# `update` and `install` in one layer: `apt-get update` exits 0 even when
# every index fetch fails, so a separate layer would cache an empty index.
RUN DEBIAN_FRONTEND=noninteractive apt-get update --error-on=any \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes \
        curl git jq ripgrep \
        nginx postgresql \
        kustomize skopeo
RUN curl -fsSL https://pb33f.io/wiretap/install.sh | bash

# install postgrest
ARG POSTGREST_VERSION=13.0.8
RUN curl -fsSL "https://github.com/PostgREST/postgrest/releases/download/v${POSTGREST_VERSION}/postgrest-v${POSTGREST_VERSION}-ubuntu-aarch64.tar.xz" | tar xJ -C /usr/local/bin postgrest

# set up user and workspace
ARG USER=kiko
ARG WORK=/workspace
RUN useradd --create-home --shell /bin/bash ${USER}
RUN mkdir -p ${WORK}
RUN chown ${USER}:${USER} ${WORK}

# postgresql setup to run cluster using `pg_ctlcluster 18 main start`
RUN usermod -aG ssl-cert ${USER}
RUN chown -R ${USER}:${USER} /etc/postgresql /var/*/postgresql
RUN sed -i 's/peer$/trust/' /etc/postgresql/18/main/pg_hba.conf
ENV PGUSER=postgres
ENV PGDATABASE=postgres

USER ${USER}
WORKDIR ${WORK}
ENV PATH="/home/${USER}/.local/bin:${PATH}"

# `uv`, python & tools
COPY --from=uv /uv /uvx /usr/local/bin
RUN uv python install --default 3.14
RUN uv tool install editorconfig-checker
RUN uv tool install lefthook
RUN uv tool install ruff
RUN uv tool install tox
RUN uv tool install yamllint
RUN uv tool install yq

# install claude code
RUN curl -sSL https://claude.ai/install.sh | bash
RUN ln -sf /home/${USER}/.claude/claude.json /home/${USER}/.claude.json

ENTRYPOINT ["claude"]
