#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
"""Regenerate system-packages.txt from a Fedora comps file.

Reimplements the parts of Fedora's comps-sync.py that produce
fedora-common-ostree-pkgs.yaml, the desktop platform layer shared by every
Fedora Atomic Desktop. Run it against a new release's comps and commit the
diff, the same workflow workstation-ostree-config uses.

  ./sync-system-packages.py /path/to/comps-rawhide.xml.in

Get the comps file from the Fedora comps repository, or out of the repodata of
any Fedora repo (repomd.xml points at the comps entry).
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET

ARCHES = ("x86_64", "aarch64")

ENVIRONMENT = "workstation-product-environment"

# Groups Fedora drops from the environment. gnome-desktop and libreoffice are
# not wanted here either; container-management is already in the base image.
EXCLUDE_GROUPS = {"gnome-desktop", "libreoffice", "container-management"}

# base-x was moved from the environment's grouplist to its optionlist in F40,
# so expanding the environment alone yields no mesa and no X drivers.
EXTRA_GROUPS = ("base-x",)

# Per-group package excludes, from Fedora's comps-sync-exclude-list.yml.
EXCLUDE = {
    "core": ["dnf", "dnf-plugins-core", "yum", "dracut-config-rescue",
             "parted", "grubby", "grubby-deprecated", "ncurses"],
    "workstation-product": [
        "dnf", "dnf-plugins-core", "deltarpm",
        "python3-dnf-plugin-system-upgrade", "fedora-release-workstation",
        "filesystem", "mailcap", "setuptool", "tcp_wrappers", "ppp",
        "crontabs", "at", "abrt-cli", "abrt-desktop", "abrt-java-connector",
        "unoconv", "git", "rhythmbox", "evolution", "evolution-ews",
        "evolution-help", "mediawriter", "psacct", "rdist", "jwhois",
        "tcpdump", "telnet", "traceroute", "net-tools", "nmap-ncat",
        "symlinks", "dosfstools", "dos2unix", "desktop-backgrounds-gnome",
        "gnome-shell-extension-background-logo", "pinentry-gnome3",
        "qgnomeplatform-qt5",
    ],
    "networkmanager-submodules": ["dhcp-client"],
    "printing": ["cups-pk-helper", "ghostscript"],
}

EXCLUDE_ALL = [re.compile(x) for x in
               ("PackageKit.*", "gstreamer1-plugin-openh264",
                "mozilla-openh264", "openh264")]

# Plasma is built from source and Qt5 is not shipped, so the GNOME-styled Qt5
# integration and the Workstation branding that Fedora keeps for all its
# desktops are dropped here.
DROP = {"fros-gnome", "fedora-workstation-backgrounds", "orca", "adwaita-qt5",
        "qadwaitadecorations-qt5", "qt5-qtbase", "qt5-qtbase-gui",
        "qt5-qtdeclarative", "qt5-qtxmlpatterns",
        # Retired or obsoleted since the comps file this was generated from.
        # basesystem is pulled in through an Obsoletes, so dnf installs it but
        # rpm -q on the name fails and it shows up as unresolved.
        "basesystem", "xorg-x11-drv-fbdev", "xorg-x11-drv-vesa"}

# comps-sync's include_list: needed, but not listed in comps anywhere.
INCLUDE = ("kernel", "kernel-modules", "kernel-modules-extra")

# Fedora policy is that systemd preset files ship with fedora-release; in F45
# they were split into their own packages. Kinoite installs both of these.
# Without them the image inherits the base image's server preset policy and
# every desktop unit has to be enabled by hand.
PRESETS = ("redhat-systemd-presets-desktop", "redhat-systemd-presets-desktop-atomic")

# Desktop services that reach Kinoite only as weak dependencies of the KDE
# packages this image replaces, so nothing in comps and nothing in fedora.yaml
# asks for them. install-kde-deps.py harvests recommends now, but that only
# runs during a full KDE rebuild; these are the ones worth having immediately.
RUNTIME = (
    # powerdevil's power profiles have no backend without tuned-ppd
    ("tuned", ARCHES),
    ("tuned-ppd", ARCHES),
    ("intel-lpmd", ("x86_64",)),
    # screen rotation, ambient light, HID quirks
    ("iio-sensor-proxy", ARCHES),
    ("udev-hid-bpf", ARCHES),
    # fingerprint auth
    ("fprintd", ARCHES),
    ("fprintd-pam", ARCHES),
    # tray icons for GTK and legacy apps
    ("libappindicator-gtk3", ARCHES),
    # gpg prompts land on pinentry-gnome3 otherwise
    ("pinentry-qt", ARCHES),
    # MIPI/IPU6 laptop cameras
    ("intel-vsc-firmware", ("x86_64",)),
    # glibc-all-langpacks covers locales, not the fonts and spell-check set
    ("langpacks-core-en", ARCHES),
    # only gdb-minimal arrives as an rpm-build dependency
    ("gdb", ARCHES),
)

LABELS = {
    "include_list": "not in comps, added by comps-sync include_list",
    "presets": "systemd preset policy, split out of fedora-release in F45",
    "runtime": "desktop services Kinoite gets as weak deps of packages this image replaces",
}

HEADER = """# Fedora's desktop platform, minus the desktop environment itself.
#
# DO NOT EDIT. Generated by sync-system-packages.py.
#
# Expanded from the workstation-product-environment comps environment the same
# way Fedora's Atomic Desktops generate fedora-common-ostree-pkgs.yaml, the
# platform layer Silverblue and Kinoite both build on. base-x is added back
# explicitly because Fedora demoted it from the environment's grouplist to its
# optionlist in F40, and expanding the environment alone leaves the image with
# no mesa and no X drivers.
#
# Committed rather than resolved with 'dnf5 group install' for the same reason
# Fedora commits its copy: group membership moves between releases, so
# resolving at build time changes the image without anything showing up in a
# diff. Regenerate against a new release and commit the result:
#
#   ./build_files/sync-system-packages.py comps-rawhide.xml.in \\
#       -o build_files/system-packages.txt
#
# This is only the distro platform. Runtime dependencies of the KDE packages
# built from source are a separate problem, handled by install-kde-deps.py:
# nothing here supplies them, because they are rpm dependencies of packages
# this image replaces.
#
# Entries marked x86_64 or aarch64 are skipped elsewhere by --skip-unavailable.
"""


def expand(root):
    groups = {g.findtext("id"): g for g in root.findall("group")}
    env = next(e for e in root.findall("environment")
               if e.findtext("id") == ENVIRONMENT)
    gids = [g.text for g in env.find("grouplist").findall("groupid")]

    pkgs = {}
    for gid in list(gids) + list(EXTRA_GROUPS):
        if gid in EXCLUDE_GROUPS or gid not in groups:
            continue
        group_excl = set(EXCLUDE.get(gid, ()))
        for req in groups[gid].find("packagelist").findall("packagereq"):
            # libcomps treats a packagereq with no type attribute as 'default'
            if (req.get("type") or "default") not in ("mandatory", "default"):
                continue
            name = req.text
            if name in group_excl or name in DROP:
                continue
            if any(b.match(name) for b in EXCLUDE_ALL):
                continue
            arches = req.get("arch").split(",") if req.get("arch") else list(ARCHES)
            arches = [a for a in arches if a in ARCHES]
            if not arches:
                continue
            entry = pkgs.setdefault(name, [set(), set()])
            entry[0].add(gid)
            entry[1].update(arches)

    for name in INCLUDE:
        pkgs.setdefault(name, [{"include_list"}, set(ARCHES)])
    for name in PRESETS:
        pkgs.setdefault(name, [{"presets"}, set(ARCHES)])
    for name, arches in RUNTIME:
        pkgs.setdefault(name, [{"runtime"}, set(arches)])
    return pkgs


def render(pkgs):
    by_group = {}
    for name, (gids, arches) in pkgs.items():
        by_group.setdefault(",".join(sorted(gids)), []).append((name, sorted(arches)))

    lines = []
    for key in sorted(by_group, key=lambda k: (k.count(","), k)):
        lines.append(f"# --- {LABELS.get(key, key.replace(',', ' + '))} ---")
        for name, arches in sorted(by_group[key]):
            lines.append(name if len(arches) == 2 else f"{name}  # {arches[0]}")
        lines.append("")
    return HEADER + "\n" + "\n".join(lines).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("comps", help="Path to a comps XML file")
    parser.add_argument("-o", "--output", help="Write here instead of stdout")
    args = parser.parse_args()

    pkgs = expand(ET.parse(args.comps).getroot())
    body = render(pkgs)
    print(f"Expanded {len(pkgs)} packages.", file=sys.stderr)

    if args.output:
        with open(args.output, "w") as f:
            f.write(body)
    else:
        sys.stdout.write(body)


if __name__ == "__main__":
    main()
