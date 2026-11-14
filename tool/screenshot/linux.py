#!/usr/bin/env python3
"""GNOME (Wayland) の画面を、Mutter の ScreenCast の D-Bus を直接使って 1 枚 PNG に撮る。

portal と違って許可のダイアログが出ない (同じユーザーのセッションバスからなら使える)。
使い方: python3 -I tool/screenshot/linux.py OUT.png [CONNECTOR]
#1383 の検証で Claude が画面を確かめるために作った (2026-11-14 inori)。
"""
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst  # noqa: E402

out = sys.argv[1]
want_connector = sys.argv[2] if len(sys.argv) > 2 else None

Gst.init(None)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def call(dest, path, iface, method, args, ret):
    return bus.call_sync(dest, path, iface, method, args, GLib.VariantType(ret),
                         Gio.DBusCallFlags.NONE, 10000, None).unpack()


state = call("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
             "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None,
             "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})")
connectors = [m[0][0] for m in state[1]]
connector = want_connector or connectors[0]
print(f"monitors: {connectors} -> recording {connector}", file=sys.stderr)

(session_path,) = call("org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast",
                       "org.gnome.Mutter.ScreenCast", "CreateSession",
                       GLib.Variant("(a{sv})", ({},)), "(o)")
(stream_path,) = call("org.gnome.Mutter.ScreenCast", session_path,
                      "org.gnome.Mutter.ScreenCast.Session", "RecordMonitor",
                      GLib.Variant("(sa{sv})", (connector, {"cursor-mode": GLib.Variant("u", 1)})),
                      "(o)")

loop = GLib.MainLoop()
result = {"ok": False}


def on_stream_added(_conn, _sender, _path, _iface, _signal, params):
    (node_id,) = params.unpack()
    pipeline = Gst.parse_launch(
        f"pipewiresrc path={node_id} num-buffers=3 do-timestamp=true ! videoconvert ! "
        f"pngenc snapshot=false ! multifilesink location={out} max-files=1")
    pipeline.set_state(Gst.State.PLAYING)
    msg = pipeline.get_bus().timed_pop_filtered(
        10 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
    if msg is None:
        print("timeout waiting for frames", file=sys.stderr)
    elif msg.type == Gst.MessageType.ERROR:
        print(f"gst error: {msg.parse_error()}", file=sys.stderr)
    else:
        result["ok"] = True
    pipeline.set_state(Gst.State.NULL)
    loop.quit()


bus.signal_subscribe("org.gnome.Mutter.ScreenCast", "org.gnome.Mutter.ScreenCast.Stream",
                     "PipeWireStreamAdded", stream_path, None, Gio.DBusSignalFlags.NONE,
                     on_stream_added)
call("org.gnome.Mutter.ScreenCast", session_path, "org.gnome.Mutter.ScreenCast.Session",
     "Start", None, "()")
GLib.timeout_add_seconds(20, loop.quit)
loop.run()
call("org.gnome.Mutter.ScreenCast", session_path, "org.gnome.Mutter.ScreenCast.Session",
     "Stop", None, "()")
sys.exit(0 if result["ok"] else 1)
