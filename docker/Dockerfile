# Purpose: Build environment for LineageOS 20 GSI with microG.
# Ubuntu 20.04 is required — LineageOS 20's repo/Java/Python toolchain has known
# friction with 22.04+ for this build generation.
FROM ubuntu:20.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
# Match builder UID/GID to the host user so volume-mounted files aren't root-owned.
ARG HOST_UID=1000
ARG HOST_GID=1000

# Enable universe repository: needed for libsdl1.2-dev, schedtool, and others
# not in the default main+restricted set of the Docker base image.
RUN echo "deb http://archive.ubuntu.com/ubuntu focal universe" >> /etc/apt/sources.list \
    && echo "deb http://archive.ubuntu.com/ubuntu focal-updates universe" >> /etc/apt/sources.list

# Install LineageOS 20 build prerequisites.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bc \
       bison \
       build-essential \
       ccache \
       curl \
       flex \
       g++-multilib \
       gcc-multilib \
       git \
       git-lfs \
       gnupg \
       gperf \
       imagemagick \
       lib32readline-dev \
       lib32z1-dev \
       libelf-dev \
       liblz4-tool \
       libsdl1.2-dev \
       libssl-dev \
       libxml2 \
       libxml2-utils \
       lzop \
       pngcrush \
       rsync \
       schedtool \
       squashfs-tools \
       xsltproc \
       zip \
       zlib1g-dev \
       python-is-python3 \
       python3 \
       openjdk-11-jdk \
    && rm -rf /var/lib/apt/lists/*

# ncurses:
# clang-3289846 is an old binary linked against ncurses 5. 
# Ubuntu 20.04 ships ncurses 6 by default; the .so.5 ABI lives in separate compat packages. 
# Ubuntu 20.04 dropped them from its baseline minimal install.
# unzip:
# guice_munge_manifest step needs to unzip a JAR
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libncurses5 \
       unzip \
    && rm -rf /var/lib/apt/lists/*

# Pipeline-specific tooling — packages this pipeline needs beyond the
# LineageOS build prerequisites. Grows as the pipeline gains features; kept
# in a separate RUN so adding entries here doesn't rebuild the base layer.
# Each entry must do its own apt-get update + cleanup (a previous layer's
# cached index would be removed by its own `rm -rf`, so we can't share).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# Install Google's repo tool from the canonical source.
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo \
    && chmod a+x /usr/local/bin/repo

# Initialise git-lfs system-wide (LineageOS manifest fetches LFS objects).
RUN git lfs install --system

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV USE_CCACHE=1
ENV CCACHE_DIR=/srv/ccache
ENV CCACHE_EXEC=/usr/bin/ccache
# Prepend JAVA_HOME/bin so the correct JDK wins even if others are present.
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Create a non-root builder user whose UID/GID match the invoking host user.
# This prevents volume mounts from appearing root-owned inside the container.
RUN groupadd --gid "${HOST_GID}" builder \
    && useradd \
       --uid "${HOST_UID}" \
       --gid "${HOST_GID}" \
       --create-home \
       --shell /bin/bash \
       builder

# Pre-create /srv mount points owned by builder.
# If Docker auto-creates volume targets they are root-owned; doing it here gives
# builder ownership before the first mount.
RUN mkdir -p /srv/src /srv/ccache /srv/keys /srv/intermediate /srv/out /srv/boot_img \
    && chown -R builder:builder /srv

# Copy pipeline files. Build context must be the repository root:
#   docker build -f docker/Dockerfile .
COPY docker/entrypoint.sh /opt/pipeline/entrypoint.sh
COPY docker/fix-perms-entrypoint.sh /usr/local/bin/fix-perms-entrypoint.sh
COPY scripts/ /opt/pipeline/scripts/
COPY config/ /opt/pipeline/config/

RUN chmod +x /opt/pipeline/entrypoint.sh /usr/local/bin/fix-perms-entrypoint.sh \
    && find /opt/pipeline/scripts -name '*.sh' -exec chmod +x {} + \
    && chown -R builder:builder /opt/pipeline

USER builder

# Set the git identity that repo init requires (it will prompt interactively if absent).
RUN git config --global user.email "builder@lineage-gsi-builder.local" \
    && git config --global user.name "LineageOS GSI Builder" \
    && git config --global color.ui false

WORKDIR /srv/src

# Container must start as root so fix-perms-entrypoint.sh can chown the bind-mounted
# /srv directories, then it drops to builder via runuser.
USER root

ENTRYPOINT ["/usr/local/bin/fix-perms-entrypoint.sh"]
