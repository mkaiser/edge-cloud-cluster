# Source: https://github.com/pulumi/pulumi-docker-containers/blob/main/docker/pulumi/Dockerfile
FROM pulumi/pulumi
# pulumi/pulumi-nodejs:3.228.0

# Use Node.js 20 from Pulumi’s built‑in fnm (no apt‑nodejs/npm mess)
RUN fnm install 20 \
    && fnm alias 20 default

# Fix Debian 13 (trixie) sources list (no COPY --from!)
RUN echo 'deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware' > /etc/apt/sources.list \
 && echo 'deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware' >> /etc/apt/sources.list \
 && echo 'deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware' >> /etc/apt/sources.list

# Basic helpers, WG, ping, SSH server + FreeLens deps
RUN apt-get update \
    && apt-get install -y \
        dnsutils \
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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Non‑root user (standard Pulumi style)
ARG USER_NAME=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USER_NAME \
    && useradd --uid $USER_UID --gid $USER_GID --shell /bin/bash -m $USER_NAME \
    && mkdir -p /etc/sudoers.d \
    && echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER_NAME \
    && chmod 0440 /etc/sudoers.d/$USER_NAME

# Go + Pulumi cache paths
RUN mkdir -p /go/bin \
    && chown -R $USER_NAME: /go \
    && mkdir -p /home/$USER_NAME/.pulumi/bin \
    && chown -R $USER_NAME: /home/$USER_NAME/.pulumi

USER $USER_NAME

# Fix XDG paths for vscode‑like editors
ENV XDG_CONFIG_HOME=/home/$USER_NAME/.config
ENV XDG_CACHE_HOME=/home/$USER_NAME/.cache

ENV KUBECONFIG=/home/$USER_NAME/.kube/config
RUN mkdir -p /home/$USER_NAME/.kube

# Add PATH and aliases
RUN echo "Setting path and bash_aliases" \
    && echo "export PATH=/home/$USER_NAME/.pulumi:/home/$USER_NAME/.pulumi/bin:/go/bin:/usr/local/go/bin:$PATH" >> /home/$USER_NAME/.bashrc \
    && echo "alias l='ls -aF'" >> /home/$USER_NAME/.bash_aliases \
    && echo "alias ll='ls -ahlF'" >> /home/$USER_NAME/.bash_aliases \
    && echo "alias ls='ls --color=auto --group-directories-first'" >> /home/$USER_NAME/.bash_aliases \
    && echo "alias pu='pulumi up'" >> /home/$USER_NAME/.bash_aliases \
    && echo "alias pd='pulumi down'" >> /home/$USER_NAME/.bash_aliases
