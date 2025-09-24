#!/bin/bash
set -oue pipefail

log() {
    echo -e "\n\033[1;34m==> $1\033[0m\n"
}

error() {
    echo -e "\n\033[1;31mERROR: $1\033[0m\n" >&2
}

COPRS=(
    "solopasha/plasma-unstable"
    "solopasha/kde-gear-unstable"
)

### Enable COPRs and set priority
for copr in "${COPRS[@]}"; do
    log "Enabling COPR: $copr"
    dnf5 -y copr enable "$copr" || error "Failed to enable COPR: $copr"
    log "Setting priority=1 for $copr"
    dnf5 -y config-manager setopt "copr:copr.fedorainfracloud.org:${copr////:}.priority=1" || error "Failed to set priority for $copr"
done

### Perform package swaps
for copr in "${COPRS[@]}"; do
    log "Processing COPR: $copr"
    copr_repo="copr:copr.fedorainfracloud.org:${copr////:}"
    
    # Get package list from COPR
    pkg_list=$(dnf5 repoquery --qf '%{name}\n' --repo="$copr_repo" | sort -u)
    
    if [[ -z "$pkg_list" ]]; then
        echo "  ⚠ No packages found in $copr_repo (skipping)"
        continue
    fi

    while IFS= read -r pkg; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            echo "  🔄 Swapping $pkg (using $copr_repo)"
            if ! dnf5 swap -y --allowerasing \
               --repo="$copr_repo" "$pkg" "$pkg" 2>/tmp/dnf-error; then
                
                error "Swap failed: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
                echo "  ⏩ Skipping $pkg"
            fi
        else
            echo "  ⏩ Skipping $pkg (not installed)"
        fi
    done <<< "$pkg_list"
done

### Clean up
rm -f /tmp/dnf-error

### 🔧 KDE Build Dependencies
log "Installing KDE build dependencies..."
if ! dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    git python3-dbus python3-pyyaml python3-setproctitle clang-devel kf6-kirigami-devel kf6-qqc2-desktop-style-devel kf6-kirigami-addons-devel clang-tools-extra git-clang-format jq 2>/tmp/dnf-error; then
    error "Some KDE build dependencies failed to install: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
fi

### Get KDE dependencies list
log "Fetching KDE dependency list..."
kde_deps=$(curl -s 'https://invent.kde.org/sysadmin/repo-metadata/-/raw/master/distro-dependencies/fedora.ini' |
    sed '1d' | grep -vE '^\s*#|^\s*$')

if [[ -z "$kde_deps" ]]; then
    error "Failed to fetch KDE dependencies list"
else
    log "Installing KDE dependencies..."
    echo "$kde_deps" | xargs dnf5 install -y --skip-broken --skip-unavailable --allowerasing 2>/tmp/dnf-error || \
        error "Some KDE dependencies failed to install: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
fi

### 🎮 Development Tools
log "Installing additional dev tools..."
dev_tools=(neovim zsh flatpak-builder kdevelop kdevelop-devel kdevelop-libs)
for tool in "${dev_tools[@]}"; do
    if ! dnf5 install -y --skip-broken --skip-unavailable --allowerasing "$tool" 2>/tmp/dnf-error; then
        error "Failed to install $tool: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
    fi
done

### 🛠 Install kde-builder (manual clone + symlinks)
log "Installing kde-builder..."
tmpdir=$(mktemp -d)
pushd "$tmpdir" >/dev/null

git clone https://invent.kde.org/sdk/kde-builder.git
cd kde-builder

mkdir -p /usr/share/kde-builder
cp -r ./* /usr/share/kde-builder

mkdir -p /usr/bin
ln -sf /usr/share/kde-builder/kde-builder /usr/bin/kde-builder

mkdir -p /usr/share/zsh/site-functions
ln -sf /usr/share/kde-builder/data/completions/zsh/_kde-builder \
    /usr/share/zsh/site-functions/_kde-builder
ln -sf /usr/share/kde-builder/data/completions/zsh/_kde-builder_projects_and_groups \
    /usr/share/zsh/site-functions/_kde-builder_projects_and_groups

popd >/dev/null
rm -rf "$tmpdir"

### 🛳 Install latest winboat
log "Installing latest winboat..."
REPO="TibixDev/winboat"
tag=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name')
version="${tag#v}"
url="https://github.com/$REPO/releases/download/$tag/winboat-${version}-x86_64.rpm"

log "Downloading $url"
curl -L -o "winboat-${version}.rpm" "$url"

log "Installing winboat ${version}"
dnf5 install -y "./winboat-${version}.rpm" || error "Failed to install winboat"

### 🔌 Enable systemd units
log "Enabling podman socket..."
systemctl enable podman.socket || error "Failed to enable podman.socket"

log "Enabling waydroid service..."
systemctl enable waydroid-container.service || error "Failed to enable waydroid-container.service"

log "Enabling and starting docker..."
systemctl enable --now docker.service || error "Failed to enable/start docker"
