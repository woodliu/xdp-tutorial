#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Script to setup and manage test environment for the XDP tutorial.
# See README.org for instructions on how to use.
#
# Author:   Toke Høiland-Jørgensen (toke@redhat.com)
# Date:     6 March 2019
# Copyright (c) 2019 Red Hat

set -o errexit
set -o nounset
umask 077

source $(dirname $0)/config.sh

NEEDED_TOOLS="ethtool ip tc"
MAX_NAMELEN=15


# Global state variables that will be set by options etc below
GENERATE_NEW=0
NEEDS_CLEANUP=0 # triggers cleanup if 1 when cleanup function runs
STATEFILE=
CMD=
NS=

# State variables that are written to and read from statefile
STATEVARS="PREFIX"
PREFIX=

die()
{
    echo "$1" >&2
    exit 1
}

check_prereq()
{
    for t in $NEEDED_TOOLS; do
        which "$t" > /dev/null || die "Missing required tools: $t"
    done

    if [ "$EUID" -ne "0" ]; then
        die "This script needs root permissions to run."
    fi

    [ -d "$STATEDIR" ] || mkdir -p "$STATEDIR" || die "Unable to create state dir $STATEDIR"
}

get_nsname()
{
    local GENERATE=${1:-0}

    if [ -z "$NS" ]; then
        [ -f "$STATEDIR/current" ] && NS=$(< "$STATEDIR/current")

        if [ "$GENERATE" -eq "1" ] && [ -z "$NS" -o "$GENERATE_NEW" -eq "1" ]; then
            NS=$(printf "%s-%04x" "$GENERATED_NAME_PREFIX" $RANDOM)
        fi
    fi

    if [ "${#NS}" -gt "$MAX_NAMELEN" ]; then
        die "Environment name '$NS' is too long (max $MAX_NAMELEN)"
    fi

    STATEFILE="$STATEDIR/${NS}.state"
}

ensure_nsname()
{
    [ -z "$NS" ] && die "No environment selected; use --name to select one"
    [ -e "$STATEFILE" ] || die "Environment for $NS doesn't seem to exist"

    echo "$NS" > "$STATEDIR/current"

    read_statefile
}

get_num()
{
    local num=1
    if [ -f "$STATEDIR/highest_num" ]; then
        num=$(( 1 + $(< "$STATEDIR/highest_num" )))
    fi

    echo $num > "$STATEDIR/highest_num"
    printf "%x" $num
}

write_statefile()
{
    [ -z "$STATEFILE" ] && return 1
    echo > "$STATEFILE"
    for var in $STATEVARS; do
        echo "${var}='$(eval echo '$'$var)'" >> "$STATEFILE"
    done
}

read_statefile()
{
    local value
    for var in $STATEVARS; do
        value=$(source "$STATEFILE"; eval echo '$'$var)
        eval "$var=\"$value\""
    done
}

cleanup_setup()
{
    echo "Error during setup, removing partially-configured environment '$NS'" >&2
    set +o errexit
    ip netns del "$NS" 2>/dev/null
    ip link del dev "$NS" 2>/dev/null
    rm -f "$STATEFILE"
}

cleanup_teardown()
{
    echo "Warning: Errors during teardown, partial environment may be left" >&2
}


cleanup()
{
    local cleanup_func=
    if [ "$NEEDS_CLEANUP" -eq 1 ]; then
        case "$CMD" in
            setup|teardown)
                cleanup_func="cleanup_${CMD}"
                ;;
        esac
    fi

    [ -n "$cleanup_func" ] && $cleanup_func

    local statefiles=("$STATEDIR"/*.state)

    if [ "${#statefiles[*]}" -eq 1 ] && [ ! -e "${statefiles[0]}" ]; then
        rm -f "${STATEDIR}/highest_num" "${STATEDIR}/current"
        rmdir "$STATEDIR"
    fi
}

setup()
{
    get_nsname 1

    echo "Setting up new environment '$NS'"

    [ -e "$STATEFILE" ] && die "Environment for '$NS' already exists"

    local NUM=$(get_num "$NS")
    local PEERNAME="testl-ve-$NUM"
    [ -z "$PREFIX" ] && PREFIX="${IP_SUBNET}:${NUM}::"

    NEEDS_CLEANUP=1

    ip netns add "$NS"
    ip link add dev "$NS" type veth peer name "$PEERNAME"
    ethtool -K "$NS" rxvlan off txvlan off
    ethtool -K "$PEERNAME" rxvlan off txvlan off
    ip link set dev "$PEERNAME" netns "$NS"
    ip link set dev "$NS" up
    sysctl -w net.ipv6.conf.$NS.accept_dad=0 >/dev/null
    ip addr add dev "$NS" "${PREFIX}2/${IP_PREFIX_SIZE}"

    ip -n "$NS" link set dev "$PEERNAME" name veth0
    ip -n "$NS" link set dev lo up
    ip -n "$NS" link set dev veth0 up
    ip netns exec "$NS" sysctl -w net.ipv6.conf.veth0.accept_dad=0 >/dev/null
    ip -n "$NS" addr add dev veth0 "${PREFIX}1/${IP_PREFIX_SIZE}"
    write_statefile

    NEEDS_CLEANUP=0

    echo "Setup environment '$NS' with peer ip ${PREFIX}1. Testing ping:"
    echo ""
    ping -c 1 "${PREFIX}1"

    echo "$NS" > "$STATEDIR/current"
}

teardown()
{
    get_nsname && ensure_nsname "$NS"

    echo "Tearing down environment '$NS'"

    NEEDS_CLEANUP=1

    ip link del dev "$NS"
    ip netns del "$NS"
    rm -f "$STATEFILE"

    if [ -f "$STATEDIR/current" ]; then
        local CUR=$(< "$STATEDIR/current" )
        [[ "$CUR" == "$NS" ]] && rm -f "$STATEDIR/current"
    fi

    NEEDS_CLEANUP=0
}

reset()
{
    teardown && setup
}

ns_exec()
{
    get_nsname && ensure_nsname "$NS"

    ip netns exec "$NS" "$@"
}

enter()
{
    ns_exec "${SHELL:-bash}"
}

status()
{
    get_nsname

    echo "Currently selected environment: ${NS:-None}"
    if [ -n "$NS" ] && [ -e "$STATEFILE" ]; then
        read_statefile
        echo -n "  Namespace: "; ip netns | grep "^$NS"
        echo    "  Prefix:    ${PREFIX}/${IP_PREFIX_SIZE}"
        echo -n "  Iface:     "; ip -br a show dev "$NS" | sed 's/\s\+/ /g'
    fi
    echo ""

    echo "All existing environments:"
    for f in "$STATEDIR"/*.state; do
        if [ ! -e "$f" ]; then
            echo "  No environments exist"
            break
        fi
        NAME=$(basename "$f" .state)
        echo "  $NAME"
    done
}

usage()
{
    local FULL=${1:-}

    echo "Usage: $0 [options] <command> [param]"
    echo ""
    echo "Commands:"
    echo "setup               Setup and initialise new environment"
    echo "teardown            Tear down existing environment"
    echo "reset               Reset environment to original state"
    echo "exec <command>      Exec <command> inside test environment"
    echo "enter               Execute shell inside test environment"
    echo "status              Show status of test environment"
    echo ""

    if [ -z "$FULL" ] ; then
        echo "Use --help to see the list of options."
        exit 1
    fi

    echo "Options:"
    echo "-h, --help          Show this usage text"
    echo "-n, --name <name>   Set name of test environment. If not set, the last used"
    echo "                    name will be used, or a new one generated."
    echo "-g, --gen-new       Generate a new test environment name even though an existing"
    echo "                    environment is selected as the current one."
    exit 1
}


OPTS="hn:g"
LONGOPTS="help,name:,gen-new"

OPTIONS=$(getopt -o "$OPTS" --long "$LONGOPTS" -- "$@")
[ "$?" -ne "0" ] && usage >&2 || true

eval set -- "$OPTIONS"


while true; do
    arg="$1"
    shift

    case "$arg" in
        -h | --help)
            usage full >&2
            ;;
        -n | --name)
            NS="$1"
            shift
            ;;
        -g | --gen-new)
            GENERATE_NEW=1
            ;;
        -- )
            break
            ;;
    esac
done

[ "$#" -eq 0 ] && usage >&2

case "$1" in
    "setup"|"teardown"|"reset"|"enter"|"status")
        CMD="$1"
        shift
        ;;
    "exec")
        CMD=ns_exec
        shift
        ;;
    *)
        usage >&2
        ;;
esac

trap cleanup EXIT
check_prereq
$CMD "$@"
