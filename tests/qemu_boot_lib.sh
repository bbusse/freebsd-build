#!/usr/bin/env bash
#
# Shared by test_boot_qemu_freebsd.sh and test_boot_qemu_nanobsd.sh, which
# set DISK_IMAGE and then source this file. Not a test file of its own
# (it isn't named test_*, so nothing passes it to bash_unit): it provides
# bash_unit's setup_suite and teardown_suite plus the boot -> login ->
# shell test sequence.
#
# The guest's first serial port is wired to a FIFO pair (qemu's
# -serial pipe:), everything the guest prints is mirrored into a log file
# the tests poll, and that log (plus qemu's own output) is printed when
# the suite ends, so a failed boot leaves a console transcript in the CI
# log rather than just "FAILURE".
#
# Acceleration: KVM when the guest arch matches the host and /dev/kvm is
# usable. GitHub's x86_64 Ubuntu runners have /dev/kvm, but the runner
# user can only open it after a udev rule (run-tests-bash-unit.yml's
# enable_kvm input); otherwise this falls back to TCG, which is several
# times slower - hence the generous BOOT_TIMEOUT. wait_for_pattern returns
# as soon as the pattern shows up or qemu exits, so a long timeout costs
# nothing on success. QEMU_ACCEL=tcg forces TCG.
#
# amd64 boots the image's MBR (NanoBSD) or protective MBR and gptzfsboot
# (FreeBSD) through qemu's default SeaBIOS, with the disk on AHCI so it
# probes as ada0 (NanoBSD's fstab hardcodes NANO_DRIVE=ada0). arm64 boots
# UEFI firmware from qemu-efi-aarch64 on qemu's virt machine, with the
# disk on virtio-blk.

# qemu option values are comma-separated, not misplaced array separators
# shellcheck disable=SC2054

QEMU_ARCH="${QEMU_ARCH:-amd64}"
QEMU_MEM="${QEMU_MEM:-1024}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-60}"
SHELL_TIMEOUT="${SHELL_TIMEOUT:-30}"
# Set by image-builder's freebsd_customize_image (freebsd_ci_root_password)
ROOT_PASSWORD="${ROOT_PASSWORD:-moonshine}"
# If set, the console and qemu logs are also copied here (e.g. for an
# upload-artifact step)
BOOT_LOG_DIR="${BOOT_LOG_DIR:-}"

QEMU_PID=""
READER_PID=""
SERIAL_DIR=""
SERIAL_LOG=""
QEMU_LOG=""
PIPE_BASE=""
QEMU_BIN=""
QEMU_ACCEL_USED=""
QEMU_CONFIG_ERROR=""
QEMU_ARGS=()

host_arch() {
    case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) uname -m ;;
    esac
}

kvm_usable() {
    [ "${QEMU_ACCEL:-kvm}" = kvm ] &&
        [ "$(host_arch)" = "${QEMU_ARCH}" ] &&
        [ -r /dev/kvm ] && [ -w /dev/kvm ]
}

first_file() {
    local f
    for f in "$@"; do
        if [ -f "${f}" ]; then
            echo "${f}"
            return 0
        fi
    done
    return 1
}

# Fills QEMU_BIN, QEMU_ARGS and QEMU_ACCEL_USED for QEMU_ARCH. Sets
# QEMU_CONFIG_ERROR and returns non-zero if something needed is missing.
# Runs in the caller's shell (not a $(...) subshell), so the arrays stick
qemu_configure() {
    if kvm_usable; then
        QEMU_ACCEL_USED=kvm
    else
        QEMU_ACCEL_USED=tcg
    fi

    # -display none/-monitor none rather than -nographic: with an explicit
    # -serial, -nographic would still put the monitor on stdio.
    # romfile= skips the iPXE option ROM, only needed for network boot.
    # snapshot=on keeps the guest's writes out of the image file.
    QEMU_ARGS=(
        -m "${QEMU_MEM}"
        -display none
        -monitor none
        -no-reboot
        -serial "pipe:${PIPE_BASE}"
        -netdev user,id=net0
        -device virtio-net-pci,netdev=net0,romfile=
        -drive "if=none,id=disk0,format=raw,snapshot=on,file=${DISK_IMAGE}"
    )

    case "${QEMU_ARCH}" in
    amd64)
        QEMU_BIN=qemu-system-x86_64
        if [ "${QEMU_ACCEL_USED}" = kvm ]; then
            QEMU_ARGS+=(-accel kvm -cpu host -smp 2)
        else
            QEMU_ARGS+=(-accel tcg -cpu qemu64)
        fi
        QEMU_ARGS+=(-device ahci,id=ahci0 -device ide-hd,drive=disk0,bus=ahci0.0)
        ;;
    arm64)
        QEMU_BIN=qemu-system-aarch64
        local firmware
        if ! firmware="$(first_file \
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
            /usr/share/AAVMF/AAVMF_CODE.fd \
            /usr/share/edk2/aarch64/QEMU_EFI.fd \
            /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
            /usr/local/share/qemu/edk2-aarch64-code.fd)"; then
            QEMU_CONFIG_ERROR="No aarch64 UEFI firmware found (install qemu-efi-aarch64)"
            return 1
        fi
        if [ "${QEMU_ACCEL_USED}" = kvm ]; then
            QEMU_ARGS+=(-machine virt,gic-version=max -accel kvm -cpu host -smp 2)
        else
            QEMU_ARGS+=(-machine virt -accel tcg -cpu cortex-a72 -smp 2)
        fi
        QEMU_ARGS+=(-bios "${firmware}" -device virtio-blk-pci,drive=disk0)
        ;;
    *)
        QEMU_CONFIG_ERROR="Unsupported QEMU_ARCH: ${QEMU_ARCH} (amd64 or arm64)"
        return 1
        ;;
    esac

    if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
        QEMU_CONFIG_ERROR="${QEMU_BIN} not found (install_qemu_deps: true in CI)"
        return 1
    fi
}

# Send a line of input to the guest's serial console
send_line() {
    printf '%s\r' "$1" >&3
}

# Current size of the console log, to pass to wait_for_pattern as the
# point to start matching from
log_size() {
    wc -c <"${SERIAL_LOG}" | tr -d ' '
}

# wait_for_pattern <ERE> <timeout seconds> [byte offset]
#
# Polls the console log from the given offset on - so output from before
# the command that should produce it can't match, and neither can our
# own input, which the guest's tty echoes back - with carriage returns
# stripped, so $ anchors at the end of a line. Returns early if qemu
# exits.
wait_for_pattern() {
    local pattern="$1"
    local timeout="$2"
    local offset="${3:-0}"
    local deadline=$((SECONDS + timeout))

    while :; do
        if tail -c "+$((offset + 1))" "${SERIAL_LOG}" 2>/dev/null |
            tr -d '\r' | grep -qE -- "${pattern}"; then
            return 0
        fi
        if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
            echo "qemu exited while waiting for: ${pattern}"
            return 1
        fi
        if [ "${SECONDS}" -ge "${deadline}" ]; then
            return 1
        fi
        sleep 1
    done
}

# Each bash_unit test runs in its own subshell, so whether an earlier
# stage of the boot sequence got through is recorded in files: a later
# test then fails at once instead of waiting out its timeout against a
# guest that never got there (and possibly matching something by chance)
stage_done() {
    : >"${SERIAL_DIR}/stage.$1"
}

require_stage() {
    if [ ! -e "${SERIAL_DIR}/stage.$1" ]; then
        fail "Not attempted: the guest never reached the $1 stage"
    fi
}

setup_suite() {
    # Everything that can fail comes before anything is started: bash_unit
    # runs setup_suite in the suite's own shell, so fail here exits the
    # whole suite without running teardown_suite
    if [ ! -f "${DISK_IMAGE}" ]; then
        fail "Disk image not found: ${DISK_IMAGE} (set DISK_IMAGE to override)"
    fi

    SERIAL_DIR="$(mktemp -d)"
    SERIAL_LOG="${SERIAL_DIR}/console.log"
    QEMU_LOG="${SERIAL_DIR}/qemu.log"
    PIPE_BASE="${SERIAL_DIR}/serial"

    if ! qemu_configure; then
        rm -rf "${SERIAL_DIR}"
        fail "${QEMU_CONFIG_ERROR}"
    fi

    mkfifo "${PIPE_BASE}.in" "${PIPE_BASE}.out"
    : >"${SERIAL_LOG}"

    # Open both FIFO ends read-write from our side before qemu starts.
    # A plain open() on a FIFO blocks until a peer opens the other end;
    # opening O_RDWR bypasses that, so neither we nor qemu (started after)
    # ever deadlock waiting for the other to attach first.
    exec 3<>"${PIPE_BASE}.in"
    exec 4<>"${PIPE_BASE}.out"

    # Drain the .out side into a plain file we can grep/tail freely. The
    # children get only the descriptors they need.
    cat <&4 3>&- 4<&- >>"${SERIAL_LOG}" &
    READER_PID=$!

    printf 'Booting %s (%s, %s): %s %s\n' "${DISK_IMAGE}" "${QEMU_ARCH}" \
        "${QEMU_ACCEL_USED}" "${QEMU_BIN}" "${QEMU_ARGS[*]}" >"${QEMU_LOG}"
    "${QEMU_BIN}" "${QEMU_ARGS[@]}" </dev/null >>"${QEMU_LOG}" 2>&1 3>&- 4<&- &
    QEMU_PID=$!
}

# bash_unit enumerates test_* functions via `set`, which lists them
# alphabetically rather than in file order - these are numbered so
# alphabetical order matches the required boot -> login -> shell sequence
test_01_disk_image_boots_to_login_prompt() {
    assert "wait_for_pattern '[Ll]ogin:' ${BOOT_TIMEOUT}" \
        "Console should reach a login prompt within ${BOOT_TIMEOUT}s"
    stage_done login
}

test_02_can_log_in_as_root() {
    require_stage login
    local mark

    mark="$(log_size)"
    send_line "root"
    assert "wait_for_pattern '[Pp]assword:' ${LOGIN_TIMEOUT} ${mark}" \
        "Console should prompt for a password after the username - no prompt usually means root has no password, i.e. the CI password never reached the /etc the guest booted with"

    mark="$(log_size)"
    send_line "${ROOT_PASSWORD}"
    assert "wait_for_pattern '# \$' ${LOGIN_TIMEOUT} ${mark}" \
        "Should reach a root shell prompt after logging in"
    stage_done shell
}

test_03_shell_runs_commands() {
    require_stage shell
    local mark

    # The tty echoes the command line back, so wait for output only the
    # shell itself can produce (an expanded arithmetic expression and
    # uname -m), never for text that also appears in what we typed
    mark="$(log_size)"
    # shellcheck disable=SC2016 # expanded by the guest's shell, not here
    send_line 'echo "BOOT_TEST_$((6 * 7))_OK_$(uname -m)"'
    assert "wait_for_pattern 'BOOT_TEST_42_OK_${QEMU_ARCH}' ${SHELL_TIMEOUT} ${mark}" \
        "Shell should run a command we send and report machine ${QEMU_ARCH}"
}

dump_logs() {
    local f
    local token
    for f in "${QEMU_LOG}" "${SERIAL_LOG}"; do
        if [ -z "${f}" ] || [ ! -s "${f}" ]; then
            continue
        fi
        if [ -n "${BOOT_LOG_DIR}" ]; then
            mkdir -p "${BOOT_LOG_DIR}" && cp "${f}" "${BOOT_LOG_DIR}/"
        fi
        # Guest output must not be read as workflow commands, so it goes
        # out between ::stop-commands:: and its resume token
        token="boot-log-$$-${RANDOM}"
        if [ "${GITHUB_ACTIONS:-}" = true ]; then
            echo "::group::$(basename "${f}")"
            echo "::stop-commands::${token}"
        else
            echo "----- $(basename "${f}") -----"
        fi
        tr -d '\r' <"${f}"
        # The guest's last line may lack a newline
        echo
        if [ "${GITHUB_ACTIONS:-}" = true ]; then
            echo "::${token}::"
            echo "::endgroup::"
        fi
    done
}

teardown_suite() {
    if [ -n "${QEMU_PID}" ]; then
        kill "${QEMU_PID}" 2>/dev/null
        wait "${QEMU_PID}" 2>/dev/null
    fi
    if [ -n "${READER_PID}" ]; then
        # Let the reader drain what qemu wrote last. It never sees EOF on
        # its own (it holds the FIFO open read-write), so stop it after
        sleep 1
        kill "${READER_PID}" 2>/dev/null
        wait "${READER_PID}" 2>/dev/null
    fi
    # No 2>/dev/null here: on a bare exec it would redirect the shell's
    # stderr for good, not just for the close
    exec 3>&- 4<&-
    dump_logs
    if [ -n "${SERIAL_DIR}" ]; then
        rm -rf "${SERIAL_DIR}"
    fi
}
