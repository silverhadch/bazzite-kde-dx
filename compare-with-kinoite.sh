#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
#
# Runs on the developer's machine rather than in the build container, so it
# uses env rather than a hardcoded /bin/bash: NixOS has no /bin/bash.
#
# Print every package Fedora Kinoite rawhide has that this image does not,
# minus the ones built from source. Whatever it lists is genuinely absent, no
# inference involved: it reads both installed package sets directly.
#
#   ./compare-with-kinoite.sh [image]
#
# Needs build_files/kde-excluded-pkgs.txt, which is gitignored. Fetch it with
#   gh release download kde-nightly-dev --pattern 'kde-excluded-pkgs.txt' \
#     --output build_files/kde-excluded-pkgs.txt
# Without it every self-built KDE package is reported as missing.
set -euo pipefail

IMAGE="${1:-localhost/fedora-plasma-canary:latest}"

# fedora-ostree-desktops is an unofficial rebuild and has dropped its rawhide
# tag, so there is no single reliable name. Probe instead of hardcoding, and
# let KINOITE_IMAGE override when none of these are right.
CANDIDATES=(
    "quay.io/fedora/fedora-kinoite:rawhide"
    "quay.io/fedora-ostree-desktops/kinoite:rawhide"
    "quay.io/fedora-ostree-desktops/kinoite-nightly:rawhide"
)

resolves() {
    if command -v skopeo > /dev/null 2>&1; then
        skopeo inspect --raw "docker://$1" > /dev/null 2>&1
    else
        podman manifest inspect "$1" > /dev/null 2>&1
    fi
}

if [ -n "${KINOITE_IMAGE:-}" ]; then
    KINOITE="${KINOITE_IMAGE}"
else
    KINOITE=""
    for candidate in "${CANDIDATES[@]}"; do
        echo "Trying ${candidate}..." >&2
        if resolves "${candidate}"; then
            KINOITE="${candidate}"
            break
        fi
    done
    if [ -z "${KINOITE}" ]; then
        echo >&2
        echo "None of the known Kinoite rawhide images resolved. Set" >&2
        echo "KINOITE_IMAGE to one that does; to see what is published:" >&2
        for candidate in "${CANDIDATES[@]}"; do
            echo "  skopeo list-tags docker://${candidate%:*}" >&2
        done
        exit 1
    fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

installed() {
    podman run --rm --entrypoint /usr/bin/rpm "$1" -qa --qf '%{NAME}\n' | sort -u
}

echo "Reading ${KINOITE}..." >&2
installed "${KINOITE}" > "${WORK}/kinoite"

echo "Reading ${IMAGE}..." >&2
installed "${IMAGE}" > "${WORK}/canary"

if [ -f build_files/kde-excluded-pkgs.txt ]; then
    sort -u build_files/kde-excluded-pkgs.txt > "${WORK}/excluded"
else
    echo "Warning: build_files/kde-excluded-pkgs.txt not found, self-built" >&2
    echo "packages will be reported as missing. See the header for how to" >&2
    echo "fetch it." >&2
    : > "${WORK}/excluded"
fi

comm -23 "${WORK}/kinoite" "${WORK}/canary" \
    | comm -23 - "${WORK}/excluded"
