#!/usr/bin/env bash
#
# Boots the built FreeBSD mini-memstick image under QEMU and verifies it
# reaches a console login prompt, that root can log in with the CI
# password and that the shell runs commands.
#
# mini-memstick is MBR on amd64 (boot/mbr, an EFI System Partition and a
# freebsd slice) and GPT on arm64 (ESP + freebsd-ufs), see
# release/<arch>/make-memstick.sh. amd64 boots the legacy BIOS path under
# qemu's default SeaBIOS, arm64 boots UEFI on qemu's virt machine. Root is
# mounted by label (/dev/ufs/FreeBSD_Install), so the disk bus doesn't
# matter here.
#
# Install media normally auto-launches bsdinstall via /etc/rc.local; that
# file is removed post-build by image-builder's freebsd_customize_image()
# (along with setting the root password and the serial console), since
# here we're smoke-testing that the built kernel/world boots, not
# exercising the installer.
#
# The qemu plumbing and the test sequence are shared with the NanoBSD
# test in qemu_boot_lib.sh.

DISK_IMAGE="${DISK_IMAGE:-mini-memstick-${QEMU_ARCH:-amd64}.img}"

# shellcheck source=tests/qemu_boot_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/qemu_boot_lib.sh"
