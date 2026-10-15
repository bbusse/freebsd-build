#!/usr/bin/env bash
#
# Boots the built NanoBSD disk image under QEMU and verifies it reaches a
# console login prompt, that root can log in with the CI password and
# that the shell runs commands.
#
# amd64 only. NanoBSD images boot via legacy BIOS (boot0sio -> boot2 ->
# loader, all on the serial port via NANO_BOOT2CFG) from an MBR with a
# nested BSD label (see nanobsd's legacy.sh create_code_slice), and the
# arm64 build uses that same layout, which has no EFI boot path for
# qemu's virt machine. The disk sits on AHCI so it probes as ada0, which
# NanoBSD's fstab hardcodes (NANO_DRIVE).
#
# NanoBSD boots with /etc on a memory disk filled from /conf/base/etc
# (rc.initdiskless, because of /etc/diskless), so the root password
# image-builder's freebsd_customize_image() sets post-build has to be
# written there as well as to /etc - otherwise root logs in without a
# password prompt and test_02 fails on the missing "Password:".
#
# The qemu plumbing and the test sequence are shared with the FreeBSD
# mini-memstick test in qemu_boot_lib.sh.

DISK_IMAGE="${DISK_IMAGE:-nanobsd-${QEMU_ARCH:-amd64}-full.img}"

# shellcheck source=tests/qemu_boot_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/qemu_boot_lib.sh"
