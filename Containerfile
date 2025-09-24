# Build argument for base image selection - must be defined before first FROM
ARG BASE_IMAGE="ghcr.io/ublue-os/aurora-dx:latest"
# NEW TEST COMMENT
# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image - Aurora DX or Aurora DX NVIDIA
FROM ${BASE_IMAGE}

## Base image options:
# ghcr.io/ublue-os/aurora-dx:latest (default)
# ghcr.io/ublue-os/aurora-dx-nvidia:latest
# 
# Other Universal Blue Images: https://github.com/orgs/ublue-os/packages
# Fedora base image: quay.io/fedora/fedora-bootc:41
# CentOS base images: quay.io/centos-bootc/centos-bootc:stream10

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

# Copy custom ujust recipes and systemd service
COPY build_files/99-custom-flatpaks.just /opt/custom-flatpaks.just
COPY build_files/aurora-kdegit-dx-setup.service /usr/lib/systemd/user/

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    ostree container commit

### FIX VAR/RUN SYMLINK
RUN rm -rf /var/run && ln -s /run /var/run

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
