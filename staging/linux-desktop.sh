#!/bin/sh
# Manage the Alpine/Xvnc/LXQt desktop used by the webOS VNC app.
# Run as root (normally through org.webosbrew.hbchannel.service).

DEVICE=${ALPINE_DEVICE:-/dev/sda1}
ROOT=${ALPINE_ROOT:-/tmp/alpine}
STATE=${ALPINE_STATE:-/tmp/webos-linux-desktop}
DISPLAY_NUM=${VNC_DISPLAY:-:1}
VNC_PORT=${VNC_PORT:-5901}
GEOMETRY=${VNC_GEOMETRY:-1920x1080}
DEPTH=${VNC_DEPTH:-24}
SETSID=${SETSID:-/usr/bin/setsid}

log() {
    printf '[linux-desktop] %s\n' "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

mounted() {
    awk -v p="$1" '$2 == p { found=1 } END { exit !found }' /proc/mounts
}

pid_alive() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

read_value() {
    [ -r "$1" ] && cat "$1" 2>/dev/null
}

# Check for non-zombie processes in a process group.
group_alive() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    ps -eo pgid=,stat= 2>/dev/null |
        awk -v g="$1" '$1 == g && $2 !~ /^Z/ { found=1 } END { exit !found }'
}

self_pgid() {
    ps -o pgid= -p "$$" 2>/dev/null | tr -d ' '
}

# Wait briefly for setsid to establish the new process group.
# In the normal non-interactive shell case, the setsid process does not fork,
# so its PID should become its PGID.
wait_private_group() {
    target_pid=$1
    attempt=0

    while [ "$attempt" -lt 20 ]; do
        found_pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d ' ')

        if [ "$found_pgid" = "$target_pid" ]; then
            return 0
        fi

        if ! pid_alive "$target_pid"; then
            return 1
        fi

        sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

mount_chroot() {
    mkdir -p "$ROOT" || fail "Cannot create $ROOT"

    if ! mounted "$ROOT"; then
        [ -b "$DEVICE" ] || fail "USB block device $DEVICE not found"

        log "Mounting $DEVICE at $ROOT"
        mount -t ext4 "$DEVICE" "$ROOT" ||
            fail "Could not mount $DEVICE"
    else
        log "$ROOT is already mounted"
    fi

    [ -x "$ROOT/bin/sh" ] ||
        fail "$ROOT does not look like an Alpine root filesystem (missing /bin/sh)"

    mkdir -p \
        "$ROOT/dev/pts" \
        "$ROOT/proc" \
        "$ROOT/sys" \
        "$ROOT/tmp/xdg" ||
        fail "Cannot prepare chroot mount points"

    chmod 700 "$ROOT/tmp/xdg" 2>/dev/null || true

    if ! mounted "$ROOT/dev"; then
        mount --bind /dev "$ROOT/dev" ||
            fail "Could not bind-mount /dev"
    fi

    if ! mounted "$ROOT/proc"; then
        mount -t proc proc "$ROOT/proc" ||
            fail "Could not mount /proc"
    fi

    if ! mounted "$ROOT/sys"; then
        mount -t sysfs sysfs "$ROOT/sys" ||
            fail "Could not mount /sys"
    fi

    if ! mounted "$ROOT/dev/pts"; then
        mount --bind /dev/pts "$ROOT/dev/pts" ||
            fail "Could not bind-mount /dev/pts"
    fi
}

unmount_chroot() {
    failed=0

    # Reverse mount order. Never use lazy unmount.
    for target in \
        "$ROOT/dev/pts" \
        "$ROOT/sys" \
        "$ROOT/proc" \
        "$ROOT/dev" \
        "$ROOT"
    do
        if mounted "$target"; then
            log "Unmounting $target"

            if ! umount "$target"; then
                log "WARNING: could not unmount $target"
                failed=1
            fi
        fi
    done

    return "$failed"
}

stop_group_file() {
    file=$1
    label=$2
    pgid=$(read_value "$file")

    [ -n "$pgid" ] || return 0

    case "$pgid" in
        *[!0-9]*|'')
            log "WARNING: invalid PGID in $file; refusing to signal it"
            return 1
            ;;
    esac

    if [ "$pgid" -le 1 ] 2>/dev/null; then
        log "WARNING: unsafe PGID '$pgid'; refusing to signal it"
        return 1
    fi

    current=$(self_pgid)

    if [ "$pgid" = "$current" ]; then
        log "WARNING: $label PGID matches manager group; refusing to signal it"
        return 1
    fi

    if group_alive "$pgid"; then
        log "Sending TERM to $label process group $pgid"

        kill -TERM -- "-$pgid" 2>/dev/null || true

        n=0
        while group_alive "$pgid" && [ "$n" -lt 8 ]; do
            sleep 1
            n=$((n + 1))
        done

        if group_alive "$pgid"; then
            log "Sending KILL to remaining $label processes in group $pgid"

            kill -KILL -- "-$pgid" 2>/dev/null || true

            n=0
            while group_alive "$pgid" && [ "$n" -lt 5 ]; do
                sleep 1
                n=$((n + 1))
            done
        fi
    fi

    if group_alive "$pgid"; then
        log "WARNING: $label process group $pgid is still present"
        return 1
    fi

    rm -f "$file"
    log "$label process group $pgid has exited"

    return 0
}

cleanup() {
    # Prevent recursive cleanup if another signal arrives.
    trap '' INT TERM HUP

    log "Cleaning up desktop processes"

    desktop_ok=0
    xvnc_ok=0

    stop_group_file "$STATE/desktop.pgid" "LXQt" && desktop_ok=1
    stop_group_file "$STATE/xvnc.pgid" "Xvnc" && xvnc_ok=1

    rm -f \
        "$STATE/launcher.pid" \
        "$STATE/desktop.pid" \
        "$STATE/xvnc.pid"

    if [ "$desktop_ok" -eq 1 ] && [ "$xvnc_ok" -eq 1 ]; then
        unmount_chroot ||
            log "WARNING: one or more Alpine mounts remain busy"
    else
        log "Leaving Alpine mounted because a desktop process group may still be running"
    fi

    log "Desktop cleanup finished"
}

start_desktop() {
    [ "$(id -u)" = 0 ] || fail "Must run as root"
    [ -x "$SETSID" ] || fail "setsid not found at $SETSID"

    mkdir -p "$STATE" || fail "Cannot create state directory $STATE"

    existing=$(read_value "$STATE/launcher.pid")

    if pid_alive "$existing"; then
        log "Desktop manager already running (PID $existing)"
        exit 0
    fi

    # Do not silently discard stale process-group records.
    for file in "$STATE/desktop.pgid" "$STATE/xvnc.pgid"; do
        stale=$(read_value "$file")

        if [ -n "$stale" ] && group_alive "$stale"; then
            fail "Previous process group $stale is still running; run '$0 stop' first"
        fi

        rm -f "$file"
    done

    rm -f \
        "$STATE/launcher.pid" \
        "$STATE/desktop.pid" \
        "$STATE/xvnc.pid"

    mount_chroot

    # Start Xvnc in its own session/process group.
    log "Starting Xvnc on $DISPLAY_NUM (port $VNC_PORT)"

    "$SETSID" chroot "$ROOT" /usr/bin/env \
        HOME=/root DISPLAY="$DISPLAY_NUM" XDG_RUNTIME_DIR=/tmp/xdg \
        XDG_SESSION_TYPE=x11 QT_QPA_PLATFORM=xcb LANG=C.UTF-8 \
        /usr/bin/Xvnc "$DISPLAY_NUM" \
        -geometry "$GEOMETRY" \
        -depth "$DEPTH" \
        -localhost \
        -SecurityTypes None &

    XVNC_PID=$!

    if ! wait_private_group "$XVNC_PID"; then
        kill -TERM "$XVNC_PID" 2>/dev/null || true
        unmount_chroot
        fail "Could not establish an isolated Xvnc process group (PID $XVNC_PID)"
    fi

    XVNC_PGID=$XVNC_PID

    echo "$XVNC_PGID" > "$STATE/xvnc.pgid"
    echo "$XVNC_PID" > "$STATE/xvnc.pid"

    sleep 2

    if ! group_alive "$XVNC_PGID"; then
        rm -f "$STATE/xvnc.pgid" "$STATE/xvnc.pid"
        unmount_chroot
        fail "Xvnc exited during startup; check tigervnc and /usr/bin/Xvnc"
    fi

    # Record the manager and install cleanup traps.
    echo "$$" > "$STATE/launcher.pid"

    trap cleanup EXIT
    trap 'exit 0' INT TERM HUP

    # Start LXQt and its D-Bus session in a separate process group.
    log "Starting LXQt"

    "$SETSID" chroot "$ROOT" /usr/bin/env \
        HOME=/root DISPLAY="$DISPLAY_NUM" XDG_RUNTIME_DIR=/tmp/xdg \
        XDG_SESSION_TYPE=x11 QT_QPA_PLATFORM=xcb LANG=C.UTF-8 \
        /usr/bin/dbus-run-session -- /usr/bin/startlxqt &

    DESKTOP_PID=$!

    if ! wait_private_group "$DESKTOP_PID"; then
        log "ERROR: Could not establish an isolated LXQt process group (PID $DESKTOP_PID)"
        cleanup
        exit 1
    fi

    DESKTOP_PGID=$DESKTOP_PID

    echo "$DESKTOP_PGID" > "$STATE/desktop.pgid"
    echo "$DESKTOP_PID" > "$STATE/desktop.pid"

    log "Desktop started; VNC listening on 127.0.0.1:$VNC_PORT"

    wait "$DESKTOP_PID"
    result=$?

    log "LXQt session exited (status $result)"

    exit "$result"
}

stop_desktop() {
    [ "$(id -u)" = 0 ] || fail "Must run as root"

    mkdir -p "$STATE" || fail "Cannot access state directory $STATE"

    launcher=$(read_value "$STATE/launcher.pid")

    if pid_alive "$launcher" && [ "$launcher" != "$$" ]; then
        log "Requesting desktop shutdown (manager PID $launcher)"

        kill -TERM "$launcher" 2>/dev/null || true

        n=0
        while pid_alive "$launcher" && [ "$n" -lt 15 ]; do
            sleep 1
            n=$((n + 1))
        done
    fi

    # Fallback cleanup: only signal the isolated groups recorded by start.
    desktop_ok=0
    xvnc_ok=0

    stop_group_file "$STATE/desktop.pgid" "LXQt" && desktop_ok=1
    stop_group_file "$STATE/xvnc.pgid" "Xvnc" && xvnc_ok=1

    rm -f \
        "$STATE/launcher.pid" \
        "$STATE/desktop.pid" \
        "$STATE/xvnc.pid"

    if [ "$desktop_ok" -eq 1 ] && [ "$xvnc_ok" -eq 1 ]; then
        unmount_chroot ||
            log "WARNING: one or more Alpine mounts remain busy"
    else
        log "Leaving Alpine mounted because a desktop process group may still be running"
    fi

    log "Stop request complete"
}

status_desktop() {
    launcher=$(read_value "$STATE/launcher.pid")
    xvnc=$(read_value "$STATE/xvnc.pgid")
    desktop=$(read_value "$STATE/desktop.pgid")

    pid_alive "$launcher" &&
        log "Manager: running (PID $launcher)" ||
        log "Manager: stopped"

    group_alive "$xvnc" &&
        log "Xvnc: running (PGID $xvnc)" ||
        log "Xvnc: stopped"

    group_alive "$desktop" &&
        log "LXQt: running (PGID $desktop)" ||
        log "LXQt: stopped"

    mounted "$ROOT" &&
        log "Alpine root: mounted at $ROOT" ||
        log "Alpine root: not mounted"

    mounted "$ROOT/dev" &&
        log "/dev: mounted" ||
        log "/dev: not mounted"

    mounted "$ROOT/proc" &&
        log "/proc: mounted" ||
        log "/proc: not mounted"

    mounted "$ROOT/sys" &&
        log "/sys: mounted" ||
        log "/sys: not mounted"

    mounted "$ROOT/dev/pts" &&
        log "/dev/pts: mounted" ||
        log "/dev/pts: not mounted"
}

case "${1:-}" in
    start)  start_desktop ;;
    stop)   stop_desktop ;;
    status) status_desktop ;;
    *)
        echo "Usage: $0 {start|stop|status}" >&2
        exit 2
        ;;
esac
