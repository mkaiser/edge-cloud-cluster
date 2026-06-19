# Lightweight Pulumi image: Node-only (Node 26 + Pulumi CLI/SDK) — no Go, .NET,
# Python or Java toolchains (this is a TypeScript-only project).
# Per-language slim images: https://github.com/pulumi/pulumi-docker-containers
# renovate: datasource=docker depName=pulumi/pulumi-nodejs-26
FROM pulumi/pulumi-nodejs-26:3.246.0

# Fix Debian 13 (trixie) sources list (no COPY --from!)
RUN echo 'deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware' > /etc/apt/sources.list \
  && echo 'deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware' >> /etc/apt/sources.list \
  && echo 'deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware' >> /etc/apt/sources.list

# Basic helpers, WG, ping, SSH server + FreeLens deps
RUN apt-get update \
  && apt-get install -y \
  make \
  dnsutils \
  curl \
  python3-pip \
  unzip \
  wireguard-tools \
  iputils-ping \
  libxss1 \
  libgtk-3-0 \
  libnss3 \
  libatspi2.0-0 \
  libsecret-1-0 \
  libasound2 \
  openssh-server \
  ssh \
  xdg-utils \
  libnotify4 \
  libappindicator3-1 \
  libnotify-bin \
  libnotify-dev \
  sshpass \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Non‑root user (standard Pulumi style)
ARG USER_NAME=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN EGRP=$(getent group "$USER_GID" | cut -d: -f1 || echo "") \
    && if [ -n "$EGRP" ] && [ "$EGRP" != "$USER_NAME" ]; then groupmod -n "$USER_NAME" "$EGRP"; elif [ -z "$EGRP" ]; then groupadd --gid "$USER_GID" "$USER_NAME"; fi \
    && EUSR=$(getent passwd "$USER_UID" | cut -d: -f1 || echo "") \
    && if [ -n "$EUSR" ] && [ "$EUSR" != "$USER_NAME" ]; then usermod -l "$USER_NAME" -d "/home/$USER_NAME" -m "$EUSR"; elif [ -z "$EUSR" ]; then useradd --uid "$USER_UID" --gid "$USER_GID" --shell /bin/bash -m "$USER_NAME"; fi \
    && mkdir -p /etc/sudoers.d \
    && echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER_NAME \
    && chmod 0440 /etc/sudoers.d/$USER_NAME

# Pulumi cache path
RUN mkdir -p /home/$USER_NAME/.pulumi/bin \
  && chown -R $USER_NAME: /home/$USER_NAME/.pulumi

USER $USER_NAME

# Fix XDG paths for vscode‑like editors
ENV XDG_CONFIG_HOME=/home/$USER_NAME/.config
ENV XDG_CACHE_HOME=/home/$USER_NAME/.cache

ENV KUBECONFIG=/home/$USER_NAME/.kube/config
RUN mkdir -p /home/$USER_NAME/.kube

# Add PATH and aliases
RUN echo "Setting path and bash_aliases" \
  && echo "export PATH=/home/$USER_NAME/.local/share/fnm:/home/$USER_NAME/.pulumi:/home/$USER_NAME/.pulumi/bin:$PATH" >> /home/$USER_NAME/.bashrc \
  && echo 'eval "$(fnm env)"' >> /home/$USER_NAME/.bashrc \
  && echo "alias l='ls -aF'" >> /home/$USER_NAME/.bash_aliases \
  && echo "alias ll='ls -ahlF'" >> /home/$USER_NAME/.bash_aliases \
  && echo "alias ls='ls --color=auto --group-directories-first'" >> /home/$USER_NAME/.bash_aliases \
  && echo "alias pu='pulumi up'" >> /home/$USER_NAME/.bash_aliases \
  && echo "alias pd='pulumi down'" >> /home/$USER_NAME/.bash_aliases
