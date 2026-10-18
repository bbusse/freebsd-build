#!/usr/bin/env bash
#
# Boots the built FreeBSD ZFS image under QEMU and verifies it reaches a
# console login prompt, that root can log in with the CI password and that
# the shell runs commands.
#
# The image is release/Makefile.vm's ZFS VM image: GPT with a protective
# MBR, gptzfsboot (amd64 only), an EFI System Partition and the zroot
# pool. amd64 boots the legacy BIOS path under qemu's default SeaBIOS,
# arm64 boots UEFI on qemu's virt machine. Root is the pool's bootfs
# (zroot/ROOT/default), so the disk bus doesn't matter here.
#
# image-builder's freebsd_vm_image_config sets the root password and the
# serial console while the image is built.
#
# The qemu plumbing and the test sequence are shared with the NanoBSD
# test in qemu_boot_lib.sh.

DISK_IMAGE="${DISK_IMAGE:-freebsd-${QEMU_ARCH:-amd64}.img}"

# shellcheck source=tests/qemu_boot_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/qemu_boot_lib.sh"
