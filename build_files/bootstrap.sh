#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -oue pipefail

error() { echo -e "\n\033[1;31mERROR: $1\033[0m\n" >&2; }

# Block all 32-bit packages globally.
# Runs as root inside the build container, so no sudo: fedora-bootc does not
# ship it, and this executes before the build deps (which include sudo) land.
cat >> /etc/dnf/dnf.conf << 'EOF'

[main]
excludepkgs=*.i686
EOF

echo "==> Installing ccache..."
dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    ccache \
    || error "ccache failed to install"

echo "==> Installing system runtime deps not covered by fedora.yaml..."
dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    wireplumber \
    pipewire-pulseaudio \
    pipewire-alsa \
    accounts-daemon \
    avahi \
    upower \
    udisks2 \
    pcscd \
    || error "Some system runtime deps failed to install"

echo "==> Installing build dependencies..."
dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    sudo git ninja-build rsync openssh-clients ccache \
    python3-yaml python3-requests python3-pip python3-setproctitle ruby \
    cmake rpm-build \
    clang-devel kf6-kirigami-devel \
    kf6-kirigami-addons-devel clang-tools-extra git-clang-format jq \
    'dnf-command(repoquery)' \
    || error "Some build deps failed to install"

dnf5 group install development-tools -y || error "development-tools failed to install"

echo "==> Installing kde-builder..."
git clone https://invent.kde.org/sdk/kde-builder.git /usr/share/kde-builder
ln -sf /usr/share/kde-builder/kde-builder /usr/bin/kde-builder
mkdir -p /usr/share/zsh/site-functions
ln -sf /usr/share/kde-builder/data/completions/zsh/_kde-builder \
    /usr/share/zsh/site-functions/_kde-builder
ln -sf /usr/share/kde-builder/data/completions/zsh/_kde-builder_projects_and_groups \
    /usr/share/zsh/site-functions/_kde-builder_projects_and_groups

# Must run before install-kde-deps.py: once the exclude drop-in is written, dnf
# can no longer resolve kdevelop's kf6-* dependencies and --skip-broken would
# silently drop kdevelop from the image. Installing first lets the distro kf6
# libs come in, then remove_installed() strips them back out and the KDE tar
# supplies the real ones.
echo "==> Installing dev tools..."
dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    neovim zsh flatpak-builder kdevelop kdevelop-devel kdevelop-libs \
    || error "Some dev tools failed to install"

echo "==> Fetching and installing KDE distro dependencies..."
python3 /ctx/install-kde-deps.py

# fedora-bootc carries no desktop content and fedora.yaml only describes what
# KDE needs to compile and link, so nothing above ever asks for firmware,
# fonts, codecs, langpacks, input methods or printing. system-packages.txt is
# that layer, flattened from comps the way Fedora's own Atomic Desktops do it.
#
# Runs after install-kde-deps.py so the exclude drop-in already exists and none
# of this can pull distro Plasma or KF6 in over the self-built tree.
echo "==> Installing Fedora desktop platform..."
mapfile -t SYSTEM_PKGS < <(grep -vE '^\s*(#|$)' /ctx/system-packages.txt)
dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    "${SYSTEM_PKGS[@]}" \
    || error "Some desktop platform packages failed to install"

# --skip-unavailable means a package renamed in rawhide just vanishes from the
# image without a word. Name every one that did not land so it shows up in the
# bootstrap log; build.sh hard-fails on the subset that must never be missing.
MISSING=()
for pkg in "${SYSTEM_PKGS[@]}"; do
    rpm -q "${pkg}" > /dev/null 2>&1 || MISSING+=("${pkg}")
done
if [ "${#MISSING[@]}" -ne 0 ]; then
    error "${#MISSING[@]} package(s) in system-packages.txt did not resolve: ${MISSING[*]}"
fi
