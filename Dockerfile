FROM debian:sid-slim

ARG USER=appuser
ARG PUID=1000
ARG PGID=1000
ARG RENDER_GROUP_GID=107

ENV DOCKER_USER=$USER
ENV PUID=$PUID
ENV PGID=$PGID

USER root
RUN groupadd -g $PGID $USER
RUN groupadd -g $RENDER_GROUP_GID docker-render
RUN useradd -ms /bin/bash -u $PUID -g $PGID $USER
RUN usermod -aG docker-render $USER

RUN apt-get update

# Install sway/wayvnc + Chromium and dependencies
RUN apt-get install -y --no-install-recommends \
    sway wayvnc openssh-client openssl curl ca-certificates chromium chromium-driver chromium-sandbox

# Clean up apt cache
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy sway/wayvnc configs
COPY --chown=$USER:$USER sway/config /home/$USER/.config/sway/config
COPY --chown=$USER:$USER wayvnc/config /home/$USER/.config/wayvnc/config

# Make directory for wayvnc certs
RUN mkdir /certs
RUN chown -R $USER:$USER /certs

# enable xwayland
ARG ENABLE_XWAYLAND

# install xwayland
RUN if [ "$ENABLE_XWAYLAND" = "true" ]; then \
    apt-get update && \
    apt-get -y install xwayland && \
    echo "Xwayland installed."; \
    else \
    echo "Xwayland installation skipped."; \
    fi

# set DISPLAY for xwayland
RUN if [ "$ENABLE_XWAYLAND" = "true" ]; then \
    sed -i '/^export XDG_RUNTIME_DIR/i \
    export DISPLAY=${DISPLAY:-:0}' \
    /entrypoint_user.sh; \
    fi

# add `xwayland enable` to sway config
RUN if [ "$ENABLE_XWAYLAND" = "true" ]; then \
    sed -i 's/xwayland disable/xwayland enable/' \
    /home/$DOCKER_USER/.config/sway/config; \
    fi

ARG SWAY_UNSUPPORTED_GPU

# add `--unsupported-gpu` flag to sway command
RUN if [ "$SWAY_UNSUPPORTED_GPU" = "true" ]; then \
    sed -i 's/sway &/sway --unsupported-gpu \&/' /entrypoint_user.sh; \
    fi

ENV PYTHONUNBUFFERED=1

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

# Make directory for the app
RUN mkdir /app
RUN chown $DOCKER_USER:$DOCKER_USER /app

# Switch to the non-root user
USER $DOCKER_USER

# Set the working directory
WORKDIR /app

# Install python
RUN uv python install 3.13

# Install the Python project's dependencies using the lockfile and settings
COPY --chown=$DOCKER_USER:$DOCKER_USER pyproject.toml uv.lock /app/
RUN --mount=type=cache,target=/home/$DOCKER_USER/.cache/uv \
    uv sync --frozen --no-install-project

# Then, add the rest of the project source code and install it
COPY --chown=$DOCKER_USER:$DOCKER_USER . /app

# Sync the project's dependencies and install the project
RUN --mount=type=cache,target=/home/$DOCKER_USER/.cache/uv \
    uv sync --frozen

# Add binaries from the project's virtual environment to the PATH
ENV PATH="/app/.venv/bin:$PATH"

# Pass custom command to entrypoint script provided by the base image
CMD [".venv/bin/python", "-m" ,"app.main"]
