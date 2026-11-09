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

log() { printf '[linux-desktop] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

mounted() {
    awk -v p="$1" '$2 == p { found=1 } END { exit !found }' /proc/mounts
}

pid_alive() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

read_pid() {
    [ -r "$1" ] && cat "$1" 2>/dev/null
}

mount_chroot() {
    mkdir -p "$ROOT" || fail "Cannot create $ROOT"

    if ! mounted "$ROOT"; then
        [ -b "$DEVICE" ] || fail "USB block device $DEVICE not found"
        log "Mounting $DEVICE at $ROOT"
        mount -t ext4 "$DEVICE" "$ROOT" || fail "Could not mount $DEVICE"
    else
        log "$ROOT is already mounted"
    fi

    [ -x "$ROOT/bin/sh" ] || fail "$ROOT does not look like an Alpine root filesystem (missing /bin/sh)"

    mkdir -p "$ROOT/dev/pts" "$ROOT/proc" "$ROOT/sys" "$ROOT/tmp/xdg" || fail "Cannot prepare chroot mount points"
    chmod 700 "$ROOT/tmp/xdg" 2>/dev/null || true

    if ! mounted "$ROOT/dev"; then
        mount --bind /dev "$ROOT/dev" || fail "Could not bind-mount /dev"
    fi
    if ! mounted "$ROOT/proc"; then
        mount -t proc proc "$ROOT/proc" || fail "Could not mount /proc"
    fi
    if ! mounted "$ROOT/sys"; then
        mount -t sysfs sysfs "$ROOT/sys" || fail "Could not mount /sys"
    fi
    if ! mounted "$ROOT/dev/pts"; then
        mount --bind /dev/pts "$ROOT/dev/pts" || fail "Could not bind-mount /dev/pts"
    fi
}

unmount_chroot() {
    # Reverse mount order. Never use lazy unmount: a failure should be visible.
    for target in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/proc" "$ROOT/sys"; do
        if mounted "$target"; then
            log "Unmounting $target"
            umount "$target" || log "WARNING: could not unmount $target"
        fi
    done
    if mounted "$ROOT"; then
        log "Unmounting $ROOT"
        umount "$ROOT" || log "WARNING: could not unmount $ROOT (something may still be using it)"
    fi
}

stop_pidfile() {
    file=$1
    label=$2
    pid=$(read_pid "$file")
    if pid_alive "$pid"; then
        log "Stopping $label (PID $pid)"
        kill -TERM "$pid" 2>/dev/null || true
        n=0
        while pid_alive "$pid" && [ "$n" -lt 5 ]; do
            sleep 1
            n=$((n + 1))
        done
        if pid_alive "$pid"; then
            log "Sending KILL to $label (PID $pid)"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$file"
}

cleanup() {
    # Prevent recursive cleanup if a second signal arrives.
    trap '' INT TERM HUP
    stop_pidfile "$STATE/desktop.pid" "LXQt session"
    stop_pidfile "$STATE/xvnc.pid" "Xvnc"
    rm -f "$STATE/launcher.pid"
    unmount_chroot
    log "Desktop stopped"
}

start_desktop() {
    [ "$(id -u)" = 0 ] || fail "Must run as root"
    mkdir -p "$STATE" || fail "Cannot create state directory $STATE"

    existing=$(read_pid "$STATE/launcher.pid")
    if pid_alive "$existing"; then
        log "Desktop manager already running (PID $existing)"
        exit 0
    fi

    # Recover stale state left by a previous app crash/reboot.
    rm -f "$STATE/launcher.pid" "$STATE/desktop.pid" "$STATE/xvnc.pid"

    mount_chroot

    # Use the user's known-good Alpine environment and keep Xvnc in the foreground
    # of its chroot process so its PID can be managed by this script.
    log "Starting Xvnc on $DISPLAY_NUM (port $VNC_PORT)"
    chroot "$ROOT" /usr/bin/env \
        HOME=/root DISPLAY="$DISPLAY_NUM" XDG_RUNTIME_DIR=/tmp/xdg \
        XDG_SESSION_TYPE=x11 QT_QPA_PLATFORM=xcb LANG=C.UTF-8 \
        /usr/bin/Xvnc "$DISPLAY_NUM" -geometry "$GEOMETRY" -depth "$DEPTH" \
        -localhost -SecurityTypes None &
    XVNC_PID=$!
    echo "$XVNC_PID" > "$STATE/xvnc.pid"

    sleep 2
    if ! pid_alive "$XVNC_PID"; then
        rm -f "$STATE/xvnc.pid"
        unmount_chroot
        fail "Xvnc exited during startup; check that tigervnc is installed and /usr/bin/Xvnc exists"
    fi

    echo "$$" > "$STATE/launcher.pid"
    trap cleanup EXIT
    trap 'exit 0' INT TERM HUP

    log "Starting LXQt"
    chroot "$ROOT" /usr/bin/env \
        HOME=/root DISPLAY="$DISPLAY_NUM" XDG_RUNTIME_DIR=/tmp/xdg \
        XDG_SESSION_TYPE=x11 QT_QPA_PLATFORM=xcb LANG=C.UTF-8 \
        /usr/bin/dbus-run-session -- /usr/bin/startlxqt &
    DESKTOP_PID=$!
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
    launcher=$(read_pid "$STATE/launcher.pid")

    if pid_alive "$launcher" && [ "$launcher" != "$$" ]; then
        log "Requesting desktop shutdown (manager PID $launcher)"
        kill -TERM "$launcher" 2>/dev/null || true
        n=0
        while pid_alive "$launcher" && [ "$n" -lt 12 ]; do
            sleep 1
            n=$((n + 1))
        done
    fi

    # Fallback cleanup if the manager is gone or did not finish its trap.
    stop_pidfile "$STATE/desktop.pid" "LXQt session"
    stop_pidfile "$STATE/xvnc.pid" "Xvnc"
    rm -f "$STATE/launcher.pid"
    unmount_chroot
    log "Stop request complete"
}

status_desktop() {
    launcher=$(read_pid "$STATE/launcher.pid")
    xvnc=$(read_pid "$STATE/xvnc.pid")
    desktop=$(read_pid "$STATE/desktop.pid")
    pid_alive "$launcher" && log "Manager: running (PID $launcher)" || log "Manager: stopped"
    pid_alive "$xvnc" && log "Xvnc: running (PID $xvnc)" || log "Xvnc: stopped"
    pid_alive "$desktop" && log "LXQt: running (PID $desktop)" || log "LXQt: stopped"
    mounted "$ROOT" && log "Alpine root: mounted at $ROOT" || log "Alpine root: not mounted"
    mounted "$ROOT/dev" && log "/dev: mounted" || log "/dev: not mounted"
    mounted "$ROOT/proc" && log "/proc: mounted" || log "/proc: not mounted"
    mounted "$ROOT/sys" && log "/sys: mounted" || log "/sys: not mounted"
    mounted "$ROOT/dev/pts" && log "/dev/pts: mounted" || log "/dev/pts: not mounted"
}

case "${1:-}" in
    start)  start_desktop ;;
    stop)   stop_desktop ;;
    status) status_desktop ;;
    *)      echo "Usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
