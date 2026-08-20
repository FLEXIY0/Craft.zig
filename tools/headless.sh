#!/usr/bin/env bash
#
# Drives the client on a virtual X server, so a change to the interface can be
# looked at from a machine with no screen. Everything here is a wrapper around
# four things that each have one sharp edge:
#
#   Xvfb      dies quietly, so `start` always checks it is still there
#   xdotool   sends press and release inside one frame, which raylib's
#             isMouseButtonPressed never sees, so `click` sleeps between them
#   xdotool   key presses and releases inside one frame too, and key --window
#             uses XSendEvent, which GLFW ignores: `key` holds, over XTEST
#   xwd       is the only grabber always present, and nothing reads its format
#
# Coordinates are relative to the client window, the same ones you read off a
# screenshot. Usage:
#
#   tools/headless.sh start --singleplayer --seed=4242
#   tools/headless.sh shot /tmp/title.png
#   tools/headless.sh click 450 244        # Singleplayer, at the default size
#   tools/headless.sh type "my world"
#   tools/headless.sh key Escape
#   tools/headless.sh log
#   tools/headless.sh stop

set -euo pipefail

display=${CRAFT_DISPLAY:-:99}
screen=${CRAFT_SCREEN:-1280x720x24}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state=${TMPDIR:-/tmp}/craft-headless
log=$state/client.log

export DISPLAY=$display

mkdir -p "$state"

# The window the client opened, or nothing if it is not up yet
window_id() {
    xdotool search --class maincraft 2>/dev/null | tail -1 ||
        xdotool search --name Maincraft 2>/dev/null | tail -1
}

# Where the window sits on the root, so window relative coordinates work
window_geometry() {
    local id
    id=$(window_id)
    [ -n "$id" ] || { echo "The client has no window (see $log)" >&2; exit 1; }
    eval "$(xdotool getwindowgeometry --shell "$id")"
    echo "$X $Y $WIDTH $HEIGHT"
}

case "${1:-}" in
start)
    shift
    pgrep -x Xvfb > /dev/null || {
        Xvfb "$display" -screen 0 "$screen" > "$state/xvfb.log" 2>&1 &
        sleep 1
    }

    pkill -f 'zig-out/bin/maincraft' 2>/dev/null || true

    # llvmpipe, because a container has no GPU. This is also why the frame rate
    # measured here is the software rasteriser's and not the engine's.
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
        "$root/zig-out/bin/maincraft" "$@" > "$log" 2>&1 &

    for _ in $(seq 40); do
        [ -n "$(window_id)" ] && { echo "up: $(window_geometry)"; exit 0; }
        sleep 0.25
    done
    echo "The client never opened a window:" >&2
    tail -20 "$log" >&2
    exit 1
    ;;

shot)
    out=${2:?usage: headless.sh shot <out.png>}
    read -r x y w h <<< "$(window_geometry)"
    xwd -root -silent > "$state/shot.xwd"
    python3 "$root/tools/xwd2png.py" "$state/shot.xwd" "$out" "$x,$y,$w,$h"
    ;;

click)
    read -r x y _ _ <<< "$(window_geometry)"
    xdotool mousemove $((x + ${2:?x})) $((y + ${3:?y}))
    sleep 0.3
    xdotool mousedown 1
    sleep 0.3
    xdotool mouseup 1
    sleep 0.5
    ;;

move)
    read -r x y _ _ <<< "$(window_geometry)"
    xdotool mousemove $((x + ${2:?x})) $((y + ${3:?y}))
    sleep 0.3
    ;;

key)
    # Same sharp edge as a click: xdotool key presses and releases inside one
    # frame, and raylib's isKeyPressed only sees a key that was still down when
    # the frame polled. So hold it.
    xdotool keydown "${2:?usage: headless.sh key <key>}"
    sleep 0.3
    xdotool keyup "$2"
    sleep 0.4
    ;;

type)
    xdotool type --delay 60 "${2:?usage: headless.sh type <text>}"
    sleep 0.3
    ;;

size)
    xdotool windowsize "$(window_id)" "${2:?width}" "${3:?height}"
    sleep 0.5
    window_geometry
    ;;

log)
    tail -"${2:-30}" "$log"
    ;;

stop)
    pkill -f 'zig-out/bin/maincraft' 2>/dev/null || true
    echo stopped
    ;;

*)
    sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
