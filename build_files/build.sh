#!/bin/bash
set -oue pipefail

# ------------------------------------------------------------------
# KDE Stack Switcher + Bootstrap
# - USE_COPR=1 : use COPR repos for KDE/Plasma and build deps
# - USE_COPR=0 : use Rawhide for KDE/Plasma and build deps
# The rest of packages come from the regular Fedora repos as before.
# ------------------------------------------------------------------

# Toggle: 1 = use COPR, 0 = use Rawhide
USE_COPR=0

log() {
    echo -e "\n\033[1;34m==> $1\033[0m\n"
}

error() {
    echo -e "\n\033[1;31mERROR: $1\033[0m\n" >&2
}

# COPR list (only used if USE_COPR=1)
COPRS=(
    "solopasha/plasma-unstable"
    "solopasha/kde-gear-unstable"
)

# figure out architecture
ARCH=$(uname -m)

# temp error file
DNF_ERR=/tmp/dnf-error

# --------------------------------------------------
# Enable source repo(s)
# - If COPR mode: enable listed COPRs and set priority=1
# - If Rawhide mode: add Rawhide repo (temporarily) and set priority
# --------------------------------------------------
KDE_REPO_IDS=()
if [[ "$USE_COPR" -eq 1 ]]; then
    log "Mode: COPR KDE stack"
    for copr in "${COPRS[@]}"; do
        log "Enabling COPR: $copr"
        if ! dnf5 -y copr enable "$copr" 2>"$DNF_ERR"; then
            error "Failed to enable COPR: $copr: $(grep -v '^Last metadata' $DNF_ERR | head -n5)"
        fi
        repo_id="copr:copr.fedorainfracloud.org:${copr////:}"
        KDE_REPO_IDS+=("$repo_id")
        log "Setting priority=1 for $repo_id"
        dnf5 -y config-manager setopt "${repo_id}.priority=1" || true
    done
else
    log "Mode: Rawhide KDE stack (only KDE groups, build deps, dev tools)"
    RAW_URL="https://mirrors.fedoraproject.org/metalink?repo=rawhide&arch=$ARCH"
    log "Adding Rawhide mirrorlist repo"
    if ! dnf5 -y config-manager --add-repo "$RAW_URL" 2>"$DNF_ERR"; then
        error "Failed to add Rawhide repo: $(grep -v '^Last metadata' $DNF_ERR | head -n5)"
    fi
    # repo id is usually 'rawhide' or 'fedora-rawhide'
    KDE_REPO_IDS+=("fedora-rawhide")
    # lower priority number means higher priority; set relatively high priority so Rawhide is preferred for swaps
    dnf5 -y config-manager setopt fedora-rawhide.priority=1 || true
fi

# helper: iterate repo ids as space-separated string
REPO_FOR_DNF="${KDE_REPO_IDS[*]}"
log "KDE repo ids: $REPO_FOR_DNF"

# --------------------------------------------------
# Discover KDE groups (kde-desktop-environment / KDE Plasma Workspaces) inside the selected repo
# We prefer to use groups if they exist (comps), otherwise fall back to pattern-based repoquery.
# --------------------------------------------------

discover_kde_groups() {
    local repo="$1"
    log "Discovering KDE groups in repo: $repo"

    # try to find groups that match KDE/Plasma keywords
    local groups
    groups=$(dnf5 group list --repo="$repo" --verbose 2>/dev/null | grep -Ei 'kde|plasma' | awk '{print $1}' | tr '\n' ' ')

    if [[ -n "$groups" ]]; then
        echo "$groups"
        return 0
    fi

    # fallback: no groups — return empty
    echo ""
    return 1
}

# --------------------------------------------------
# Collect package names from groups
# --------------------------------------------------
collect_pkgs_from_groups() {
    local repo="$1"
    local groups_csv="$2"
    local pkgs_list=""

    for g in $groups_csv; do
        log "Collecting packages from group: $g"
        group_pkgs=$(dnf5 group info --repo="$repo" "$g" 2>/dev/null |
            sed -n '/Packages:/,/^[^ ]/p' |
            sed '1d;$d' |
            awk '{print $1}')
        pkgs_list+="$group_pkgs\n"
    done

    echo -e "$pkgs_list" | sort -u
}

# --------------------------------------------------
# If groups are not available, fall back to a safe pattern set
# but prefer installed packages only when swapping.
# --------------------------------------------------
collect_pkgs_fallback() {
    local repo="$1"
    dnf5 repoquery --repo="$repo" --qf '%{name}\n' 'plasma6-*' 'kf6-*' 'kde*' 'kwin*' 'kio*' 2>/dev/null | sort -u
}

# --------------------------------------------------
# Perform package swaps from repo for only packages that are currently installed
# --------------------------------------------------
swap_pkgs_from_repo() {
    local repo="$1"
    local pkg_list="$2"

    if [[ -z "$pkg_list" ]]; then
        echo "  ⚠ No packages to process for repo $repo"
        return
    fi

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if rpm -q "$pkg" >/dev/null 2>&1; then
            echo "  🔄 Swapping $pkg (from $repo)"
            if ! dnf5 swap -y --allowerasing --repo="$repo" "$pkg" "$pkg" 2>"$DNF_ERR"; then
                error "Swap failed for $pkg: $(grep -v '^Last metadata' $DNF_ERR | head -n5)"
                echo "  ⏩ Skipping $pkg"
            fi
        else
            echo "  ⏩ Skipping $pkg (not installed)"
        fi
    done <<< "$pkg_list"
}

# --------------------------------------------------
# Main: for each KDE repo id, discover groups/packages and swap
# --------------------------------------------------
for repo in "${KDE_REPO_IDS[@]}"; do
    groups=$(discover_kde_groups "$repo") || groups=""

    if [[ -n "$groups" ]]; then
        pkgs=$(collect_pkgs_from_groups "$repo" "$groups")
    else
        log "No KDE groups found in repo $repo — using fallback pattern scan"
        pkgs=$(collect_pkgs_fallback "$repo")
    fi

    if [[ -z "$pkgs" ]]; then
        log "No KDE packages found in $repo"
        continue
    fi

    swap_pkgs_from_repo "$repo" "$pkgs"
done

rm -f "$DNF_ERR"

# --------------------------------------------------
# Install KDE build dependencies (from KDE_REPO_IDS)
# Keep the package list you had, but install from the selected KDE repo so they come from Rawhide/COPR when enabled.
# --------------------------------------------------
log "Installing KDE build dependencies (sourced from KDE repo when available)"
if ! dnf5 install -y --skip-broken --skip-unavailable --allowerasing \
    --repo="${KDE_REPO_IDS[*]}" \
    git python3-dbus python3-pyyaml python3-setproctitle clang-devel \
    kf6-kirigami-devel kf6-qqc2-desktop-style-devel kf6-kirigami-addons-devel \
    clang-tools-extra git-clang-format jq 2>"$DNF_ERR"; then
    error "Some KDE build dependencies failed to install: $(grep -v '^Last metadata' $DNF_ERR | head -n5)"
fi

# --------------------------------------------------
# Get KDE dependencies list from invent.kde.org and install them (from KDE repo when possible)
# --------------------------------------------------
log "Fetching KDE dependency list from invent.kde.org"
kde_deps=$(curl -s 'https://invent.kde.org/sysadmin/repo-metadata/-/raw/master/distro-dependencies/fedora.ini' |
    sed '1d' | grep -vE '^\s*#|^\s*$') || kde_deps=""

if [[ -z "$kde_deps" ]]; then
    error "Failed to fetch KDE dependencies list or list empty"
else
    log "Installing KDE dependencies from KDE repo(s)"
    echo "$kde_deps" | xargs -r dnf5 install -y --skip-broken --skip-unavailable --allowerasing --repo="${KDE_REPO_IDS[*]}" 2>"$DNF_ERR" || \
        error "Some KDE dependencies failed: $(grep -v '^Last metadata' $DNF_ERR | head -n5)"
fi

# --------------------------------------------------
# Development tools (neovim, zsh, flatpak-builder, kdevelop...) — install from KDE repo if in Rawhide/COPR mode,
# otherwise from regular Fedora repos (dnf5 default) — we use --repo to prefer KDE_REPO_IDS but that won't block
# installation if the packages are only available in the default repos.
# --------------------------------------------------
log "Installing development tools"
dev_tools=(neovim zsh flatpak-builder kdevelop kdevelop-devel kdevelop-libs)
for tool in "${dev_tools[@]}"; do
    if ! dnf5 install -y --skip-broken --skip-unavailable --allowerasing --repo="${KDE_REPO_IDS[*]}" "$tool" 2>"$DNF_ERR"; then
        log "Attempting to install $tool from default repos"
        dnf5 install -y --skip-broken --skip-unavailable --allowerasing "$tool" 2>"$DNF_ERR" || \
            error "Failed to install $tool: $(grep -v '^Last metadata' $DNF_ERR | head -n5)"
    fi
done

# --------------------------------------------------
# kde-builder: manual clone + symlinks (keep as-is)
# --------------------------------------------------
log "Installing kde-builder..."
tmpdir=$(mktemp -d)
pushd "$tmpdir" >/dev/null

if git clone https://invent.kde.org/sdk/kde-builder.git 2>/dev/null; then
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
else
    error "Failed to clone kde-builder"
fi

popd >/dev/null
rm -rf "$tmpdir"

# --------------------------------------------------
# winboat AppImage installer (keeps existing behavior but uses ARCH variable)
# --------------------------------------------------
log "Installing latest winboat..."
REPO="TibixDev/winboat"
tag=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name') || tag=""
version="${tag#v}"
url="https://github.com/$REPO/releases/download/$tag/winboat-${version}-${ARCH}.AppImage"

if [[ -n "$tag" ]]; then
    log "Downloading $url"
    curl -L -o "winboat-${version}.AppImage" "$url" || error "Failed to download winboat AppImage"
    log "Installing winboat ${version}"
    mv "./winboat-${version}.AppImage" /usr/bin/winboat || error "Failed to install winboat"
    chmod +x /usr/bin/winboat
else
    log "Could not determine latest winboat release (skipping)"
fi

# --------------------------------------------------
# winboat icon + .desktop
# --------------------------------------------------
log "Installing winboat icon..."
install -Dm644 /dev/null "/usr/share/icons/hicolor/scalable/apps/winboat.svg"
curl -L "https://raw.githubusercontent.com/TibixDev/winboat/refs/heads/main/gh-assets/winboat_logo.svg" \
    -o "/usr/share/icons/hicolor/scalable/apps/winboat.svg" || error "Failed to download icon"

log "Creating desktop entry..."
desktop_file="/usr/share/applications/winboat.desktop"
cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=winboat
Exec=/usr/bin/winboat %U
Terminal=false
Type=Application
Icon=winboat
StartupWMClass=winboat
Comment=Windows for Penguins
Categories=Utility;
EOF

# --------------------------------------------------
# Enable systemd units
# --------------------------------------------------
log "Enabling podman socket..."
systemctl enable podman.socket || error "Failed to enable podman.socket"

log "Enabling waydroid service..."
systemctl enable waydroid-container.service || error "Failed to enable waydroid-container.service"

log "Enabling and starting docker..."
systemctl enable --now docker.service || error "Failed to enable/start docker"

log "All done. KDE stack + tools have been processed (USE_COPR=$USE_COPR)."

