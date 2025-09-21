I#!/bin/bash
set -oue pipefail

log() {
    echo -e "\n\033[1;34m==> $1\033[0m\n"
}

error() {
    echo -e "\n\033[1;31mERROR: $1\033[0m\n" >&2
}

### Add Rstudio
dnf5 -y copr enable "iucar/rstudio" || error "Failed to enable Rstudio COPR"
dnf5 install -y r R-devel rstudio gcc-gfortran || error "Failed to install R and Rstudio"

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
    git python3-dbus python3-pyyaml python3-setproctitle clang-devel kf6-kirigami-devel kf6-qqc2-desktop-style-devel kf6-kirigami-addons-devel clang-tools-extra git-clang-format 2>/tmp/dnf-error; then
    error "Some KDE build dependencies failed to install: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
fi
### Get KDE dependencies list
# log "Fetching KDE dependency list..."
# kde_deps=$(curl -s 'https://invent.kde.org/sysadmin/repo-metadata/-/raw/master/distro-dependencies/fedora.ini' |
#    sed '1d' | grep -vE '^\s*#|^\s*$')

# if [[ -z "$kde_deps" ]]; then
#    error "Failed to fetch KDE dependencies list"
# else
#    log "Installing KDE dependencies..."
#    echo "$kde_deps" | xargs dnf5 install -y --skip-broken --skip-unavailable --allowerasing 2>/tmp/dnf-error || \
#        error "Some KDE dependencies failed to install: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
# fi

### 🎮 Development Tools
# log "Installing additional dev tools..."
# dev_tools=(neovim zsh flatpak-builder kdevelop kdevelop-devel kdevelop-libs)
# for tool in "${dev_tools[@]}"; do
#     if ! dnf5 install -y --skip-broken --skip-unavailable --allowerasing "$tool" 2>/tmp/dnf-error; then
#         error "Failed to install $tool: $(grep -v '^Last metadata' /tmp/dnf-error | head -n5)"
#     fi
# done

### 🛠 Install kde-builder (manual clone + symlinks)
# log "Installing kde-builder..."
# tmpdir=$(mktemp -d)
# pushd "$tmpdir" >/dev/null

# git clone https://invent.kde.org/sdk/kde-builder.git
# cd kde-builder

# mkdir -p /usr/share/kde-builder
# cp -r ./* /usr/share/kde-builder

# mkdir -p /usr/bin
# ln -sf /usr/share/kde-builder/kde-builder /usr/bin/kde-builder

# mkdir -p /usr/share/zsh/site-functions
# ln -sf /usr/share/kde-builder/data/completions/zsh/_kde-builder \
#     /usr/share/zsh/site-functions/_kde-builder
# ln -sf /usr/share/kde-builder/data/completions/zsh/_kde-builder_projects_and_groups \
#     /usr/share/zsh/site-functions/_kde-builder_projects_and_groups

# popd >/dev/null
# rm -rf "$tmpdir"

### 📦 Flatpak installation moved to ujust recipe
# Flatpaks are now installed via ujust recipe after boot
# See build_files/99-custom-flatpaks.just

### 🛠 Install ublue-kde-dev (manual clone + symlinks)
log "Installing ublue-kde-dev..."
tmpdir=$(mktemp -d)
pushd "$tmpdir" >/dev/null

git clone https://github.com/ledif/ublue-kde-dev.git
cd ublue-kde-dev

mkdir -p /usr/share/ublue-kde-dev
cp -r ./* /usr/share/ublue-kde-dev

ln -sf /usr/share/ublue-kde-dev/ublue-kde-dev.py /usr/bin/ublue-kde-dev
chmod +x /usr/share/ublue-kde-dev/ublue-kde-dev.py

popd >/dev/null
rm -rf "$tmpdir"

### 📜 Add custom ujust recipes
log "Adding custom Flatpak management recipes to ujust..."
if [[ -f /opt/custom-flatpaks.just ]]; then
    # Copy the custom recipes file to the just directory
    cp /opt/custom-flatpaks.just /usr/share/ublue-os/just/99-custom-flatpaks.just
    
    # Add import statement to main justfile
    echo 'import "/usr/share/ublue-os/just/99-custom-flatpaks.just"' >> /usr/share/ublue-os/justfile
    
    rm /opt/custom-flatpaks.just
    echo "  ✅ Added custom Flatpak recipes to ujust"
else
    error "Custom Flatpak recipes file not found at /opt/custom-flatpaks.just"
fi

### 🔌 Enable systemd units
log "Enabling podman socket..."
systemctl enable podman.socket || error "Failed to enable podman.socket"

log "Enabling waydroid service..."
systemctl enable waydroid-container.service || error "Failed to enable waydroid-container.service"

log "Enabling Aurora KDE Git DX auto-setup service..."
systemctl --global enable aurora-kdegit-dx-setup.service || error "Failed to enable auto-setup service"
