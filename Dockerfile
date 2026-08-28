FROM ghcr.io/astral-sh/uv:latest AS uv
FROM ubuntu:26.04 AS kiko

RUN DEBIAN_FRONTEND=noninteractive apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install --yes curl git jq ripgrep

COPY --from=uv /uv /uvx /usr/local/bin

ARG USER=kiko
ARG WORK=/workspace

RUN useradd --create-home --shell /bin/bash ${USER}
RUN mkdir -p ${WORK}
RUN chown ${USER}:${USER} ${WORK}

USER ${USER}
WORKDIR ${WORK}
ENV PATH="/home/${USER}/.local/bin:${PATH}"

RUN uv python install 3.14
RUN uv tool install lefthook
RUN uv tool install ruff
RUN uv tool install tox
RUN uv tool install yq

RUN curl -sSL https://claude.ai/install.sh | bash
RUN ln -sf /home/${USER}/.claude/claude.json /home/${USER}/.claude.json

ENTRYPOINT ["claude"]
