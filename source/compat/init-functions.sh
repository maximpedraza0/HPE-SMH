#!/bin/bash
# Minimal /etc/init.d/functions shim for RHEL-style init scripts on unRAID.
# Shipped by the hpe-mgmt plugin; install.sh drops a copy at
# /etc/init.d/functions when it doesn't already exist.
#
# Only the handful of functions the HPE init scripts actually call are
# implemented — enough to satisfy hp-health, hp-snmp-agents.sh, and
# hpsmhd.redhat.  If more is ever needed, extend here.
#
# Colours match /etc/init.d/functions from RHEL 7/8 roughly so logs read
# naturally when tailed.

TERM_COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
MOVE_TO_COL="echo -en \\033[${TERM_COLS}G"
SETCOLOR_SUCCESS="echo -en \\033[1;32m"
SETCOLOR_FAILURE="echo -en \\033[1;31m"
SETCOLOR_WARNING="echo -en \\033[1;33m"
SETCOLOR_NORMAL="echo -en \\033[0;39m"

echo_success() {
    $MOVE_TO_COL
    echo -n "[  "
    $SETCOLOR_SUCCESS; echo -n "OK"; $SETCOLOR_NORMAL
    echo -n "  ]"; echo
    return 0
}

echo_failure() {
    $MOVE_TO_COL
    echo -n "["
    $SETCOLOR_FAILURE; echo -n "FAILED"; $SETCOLOR_NORMAL
    echo -n "]"; echo
    return 1
}

echo_warning() {
    $MOVE_TO_COL
    echo -n "["
    $SETCOLOR_WARNING; echo -n "WARNING"; $SETCOLOR_NORMAL
    echo -n "]"; echo
    return 1
}

echo_passed() { echo_warning; }

success() { [ "$1" ] && echo -n "$1"; echo_success; return 0; }
failure() { local rc=$? ; [ "$1" ] && echo -n "$1"; echo_failure; return "${rc:-1}"; }
passed()  { [ "$1" ] && echo -n "$1"; echo_passed;  return 0; }
warning() { [ "$1" ] && echo -n "$1"; echo_warning; return 0; }

# action "Doing X" command [args...]
action() {
    local msg="$1"; shift
    echo -n "$msg"
    if "$@"; then success; return 0; else failure; return $?; fi
}

# checkpid <pid>...   true if at least one still lives
checkpid() {
    local pid
    for pid in "$@"; do kill -0 "${pid}" 2>/dev/null && return 0; done
    return 1
}

# pidofproc [-p pidfile] program
#   emit pid(s) to stdout, exit 0 if alive
pidofproc() {
    local pidfile=""
    if [ "$1" = "-p" ]; then pidfile="$2"; shift 2; fi
    local base="${1##*/}"
    if [ -n "${pidfile}" ] && [ -r "${pidfile}" ]; then
        local pid; pid="$(cat "${pidfile}" 2>/dev/null)"
        if [ -n "${pid}" ] && checkpid "${pid}"; then
            echo "${pid}"; return 0
        fi
        return 1
    fi
    local pids; pids="$(pidof -x "${base}" "$1" 2>/dev/null)"
    [ -n "${pids}" ] && { echo "${pids}"; return 0; }
    return 1
}

# status [-p pidfile] program
status() {
    local pidfile=""
    if [ "$1" = "-p" ]; then pidfile="$2"; shift 2; fi
    local base="${1##*/}"
    local pids
    if [ -n "${pidfile}" ]; then
        if [ -r "${pidfile}" ]; then
            pids="$(cat "${pidfile}" 2>/dev/null)"
            if [ -n "${pids}" ] && checkpid "${pids}"; then
                echo "${base} (pid ${pids}) is running..."
                return 0
            fi
            echo "${base} dead but pid file exists"
            return 1
        fi
    else
        pids="$(pidof -x "${base}" "$1" 2>/dev/null)"
        if [ -n "${pids}" ]; then
            echo "${base} (pid ${pids}) is running..."
            return 0
        fi
    fi
    echo "${base} is stopped"
    return 3
}

# daemon [--check foo] [--user u] [--pidfile f] [+/-nicelevel] program [args...]
# We ignore --check, --user, nicelevel (not needed for unRAID-as-root), and
# just background the process, optionally writing a pidfile.
daemon() {
    local pidfile=""
    local nicelevel=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --check|--user) shift 2 ;;
            --pidfile) pidfile="$2"; shift 2 ;;
            +[0-9]*|-[0-9]*) nicelevel="$1"; shift ;;
            --*) shift ;;
            *) break ;;
        esac
    done
    local cmd="$1"; shift
    if [ -n "${nicelevel}" ]; then
        nice "${nicelevel}" "${cmd}" "$@" &
    else
        "${cmd}" "$@" &
    fi
    local pid=$!
    [ -n "${pidfile}" ] && echo "${pid}" > "${pidfile}"
    disown 2>/dev/null || true
    sleep 0.2
    if kill -0 "${pid}" 2>/dev/null; then success; return 0; fi
    failure; return 1
}

# killproc [-p pidfile] [-d delay] program [signal]
killproc() {
    local pidfile=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -p) pidfile="$2"; shift 2 ;;
            -d) shift 2 ;;
            *) break ;;
        esac
    done
    local prog="$1"
    local signal="${2:-TERM}"
    local base="${prog##*/}"

    local pid=""
    if [ -n "${pidfile}" ] && [ -r "${pidfile}" ]; then
        pid="$(cat "${pidfile}" 2>/dev/null)"
    fi
    [ -z "${pid}" ] && pid="$(pidof -x "${base}" "${prog}" 2>/dev/null)"

    if [ -z "${pid}" ]; then
        echo_warning; return 0
    fi
    kill "-${signal#-}" ${pid} 2>/dev/null
    # Wait up to 5 seconds for graceful exit when sending TERM.
    if [ "${signal#-}" = "TERM" ] || [ "${signal}" = "-15" ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            checkpid ${pid} || break
            sleep 0.5
        done
        checkpid ${pid} && kill -9 ${pid} 2>/dev/null
    fi
    [ -n "${pidfile}" ] && rm -f "${pidfile}"
    success; return 0
}

# Some vendor scripts source this file AND also check for
# /etc/sysconfig/init which sets BOOTUP=verbose/color/serial.  Default to
# color so that success/failure markers actually colour the output.
BOOTUP="${BOOTUP:-color}"
