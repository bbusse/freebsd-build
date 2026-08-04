#!/usr/bin/env bash
#
# Boots the built FreeBSD mini-memstick image under QEMU and verifies it
# reaches a console login prompt and that we can log in as root.
#
# CI runners have no /dev/kvm, so this boots under TCG (software emulation)
# rather than KVM - expect it to be slow. BOOT_TIMEOUT/LOGIN_TIMEOUT below
# are first-pass guesses and will likely need tuning once we see real
# timing from an actual run.
#
# mini-memstick is an MBR disk with both an MBR boot record and an EFI
# System Partition (see release/<arch>/make-memstick.sh), so it can boot
# either way - we use the MBR/legacy-BIOS path here (qemu's default
# SeaBIOS) to avoid needing OVMF firmware. The disk is attached via AHCI
# since that's compiled into GENERIC statically (unlike virtio-blk, which
# isn't guaranteed to be present).
#
# Install media normally auto-launches bsdinstall via /etc/rc.local; that
# file is removed post-build by image-builder's freebsd_customize_image()
# (along with setting the root password and enabling the serial console),
# since here we're smoke-testing that the built kernel/world boots, not
# exercising the installer.

DISK_IMAGE="${DISK_IMAGE:-mini-memstick-amd64.img}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-60}"
ROOT_PASSWORD="freebsd-ci"

QEMU_PID=""
SERIAL_DIR=""
SERIAL_LOG=""
PIPE_BASE=""
READER_PID=""

# Send a line of input to the guest's serial console
send_line() {
    printf '%s\r' "$1" >&3
}

# Poll the captured serial log for a pattern, up to a timeout (seconds).
# Bails out early if qemu has already exited (nothing left to wait for).
wait_for_pattern() {
    local pattern="$1"
    local timeout="$2"
    local waited=0

    while [ "$waited" -lt "$timeout" ]; do
        if grep -qE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
            return 0
        fi
        if [ -n "$QEMU_PID" ] && ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

setup_suite() {
    if [ ! -f "$DISK_IMAGE" ]; then
        fail "Disk image not found: $DISK_IMAGE (set DISK_IMAGE to override)"
    fi

    SERIAL_DIR="$(mktemp -d)"
    SERIAL_LOG="${SERIAL_DIR}/console.log"
    PIPE_BASE="${SERIAL_DIR}/serial"

    mkfifo "${PIPE_BASE}.in" "${PIPE_BASE}.out"
    : > "$SERIAL_LOG"

    # Open both FIFO ends read-write from our side before qemu starts.
    # A plain open() on a FIFO blocks until a peer opens the other end;
    # opening O_RDWR bypasses that, so neither we nor qemu (started after)
    # ever deadlock waiting for the other to attach first.
    exec 3<>"${PIPE_BASE}.in"
    exec 4<>"${PIPE_BASE}.out"

    # Drain the .out side into a plain file we can grep/tail freely
    cat <&4 >>"$SERIAL_LOG" &
    READER_PID=$!

    qemu-system-x86_64 \
        -m 1024 \
        -accel tcg \
        -cpu qemu64 \
        -nographic \
        -no-reboot \
        -nic user,model=virtio-net-pci \
        -serial pipe:"${PIPE_BASE}" \
        -drive if=none,format=raw,file="${DISK_IMAGE}",id=disk0 \
        -device ahci,id=ahci0 \
        -device ide-hd,drive=disk0,bus=ahci0.0 \
        >/dev/null 2>&1 &
    QEMU_PID=$!
}

# bash_unit enumerates test_* functions via `set`, which lists them
# alphabetically rather than in file order - these are numbered so
# alphabetical order matches the required boot -> login -> shell sequence
test_01_disk_image_boots_to_login_prompt() {
    assert "wait_for_pattern '[Ll]ogin:' ${BOOT_TIMEOUT}" \
        "Console should reach a login prompt within ${BOOT_TIMEOUT}s"
}

test_02_can_log_in_as_root() {
    send_line "root"
    assert "wait_for_pattern '[Pp]assword:' ${LOGIN_TIMEOUT}" \
        "Console should prompt for a password after entering the username"

    send_line "$ROOT_PASSWORD"
    assert "wait_for_pattern 'Last login|# \$' ${LOGIN_TIMEOUT}" \
        "Should reach a root shell prompt after logging in"
}

test_03_shell_is_interactive() {
    local marker="BOOT_TEST_OK_$$"
    send_line "echo ${marker}"
    assert "wait_for_pattern '${marker}' 30" \
        "Shell should echo back a command we send, confirming an interactive session"
}

teardown_suite() {
    [ -n "$READER_PID" ] && kill "$READER_PID" 2>/dev/null
    exec 3<&- 2>/dev/null
    exec 4<&- 2>/dev/null
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null
        wait "$QEMU_PID" 2>/dev/null
    fi
    [ -n "$SERIAL_DIR" ] && rm -rf "$SERIAL_DIR"
}
