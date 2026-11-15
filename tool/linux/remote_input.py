#!/usr/bin/env python3
"""GNOME (Wayland) へ、Mutter の RemoteDesktop の D-Bus を直接使って入力を送る。

portal (XWayland の XTEST も -enable-ei-portal で portal を通る) と違って許可の
ダイアログが出ない。座標は tool/screenshot/linux.py で撮った画像の画素と同じ
(モニターの物理画素) なので、撮った画像で位置を見てそのまま押せる。
#1383 の検証で Claude が画面を操作するために作った (2026-11-14 inori)。

使い方 (python3 -I tool/linux/remote_input.py <操作> ...):
  click X Y [left|right|middle]   その位置をクリックする
  dclick X Y                      ダブルクリック
  move X Y                        マウスを動かすだけ
  drag X1 Y1 X2 Y2                左ボタンでドラッグする
  scroll X Y DY                   その位置で縦にスクロールする (DY>0 で下)
  type TEXT                       ASCII の文字列を打つ (日本語は打てない)
  key KEY [KEY...]                キーを押す (同時押しは ctrl+a の形・例: Return, ctrl+shift+k)
  type-secret NAME                secrets.env の NAME の値を打つ (値は画面にも引数にも出さない)
⚠ 送る前に、狙ったウィンドウが前面にあるかを撮って確かめること (端末へ誤入力しない)。
"""
import sys
import time

import gi

gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib  # noqa: E402

BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}  # linux/input-event-codes.h
MODS = {"ctrl": "Control_L", "shift": "Shift_L", "alt": "Alt_L", "super": "Super_L"}

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def call(dest, path, iface, method, args=None, ret="()"):
    return bus.call_sync(dest, path, iface, method, args, GLib.VariantType(ret),
                         Gio.DBusCallFlags.NONE, 10000, None).unpack()


RD = "org.gnome.Mutter.RemoteDesktop"
SC = "org.gnome.Mutter.ScreenCast"


class Session:
    def __init__(self):
        (self.rd,) = call(RD, "/org/gnome/Mutter/RemoteDesktop", RD, "CreateSession", None, "(o)")
        sid = call(RD, self.rd, "org.freedesktop.DBus.Properties", "Get",
                   GLib.Variant("(ss)", (RD + ".Session", "SessionId")), "(v)")[0]
        (sc_session,) = call(SC, "/org/gnome/Mutter/ScreenCast", SC, "CreateSession",
                             GLib.Variant("(a{sv})", ({"remote-desktop-session-id": GLib.Variant("s", sid)},)),
                             "(o)")
        state = call("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                     "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None,
                     "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})")
        connector = state[1][0][0][0]
        (self.stream,) = call(SC, sc_session, SC + ".Session", "RecordMonitor",
                              GLib.Variant("(sa{sv})", (connector, {})), "(o)")
        call(RD, self.rd, RD + ".Session", "Start")
        time.sleep(0.3)

    def stop(self):
        call(RD, self.rd, RD + ".Session", "Stop")

    def _rd(self, method, sig, *args):
        call(RD, self.rd, RD + ".Session", method, GLib.Variant(sig, args))

    def move(self, x, y):
        self._rd("NotifyPointerMotionAbsolute", "(sdd)", self.stream, float(x), float(y))
        time.sleep(0.05)

    def button(self, btn, pressed):
        self._rd("NotifyPointerButton", "(ib)", BTN[btn], pressed)
        time.sleep(0.05)

    def click(self, x, y, btn="left", times=1):
        self.move(x, y)
        for _ in range(times):
            self.button(btn, True)
            self.button(btn, False)

    def keysym(self, sym, pressed):
        self._rd("NotifyKeyboardKeysym", "(ub)", sym, pressed)
        time.sleep(0.02)

    def combo(self, spec):
        parts = spec.split("+")
        syms = [Gdk.keyval_from_name(MODS.get(p, p)) for p in parts]
        if any(s in (0, 0xFFFFFF) for s in syms):
            raise SystemExit(f"unknown key: {spec}")
        for s in syms:
            self.keysym(s, True)
        for s in reversed(syms):
            self.keysym(s, False)

    def type(self, text):
        for ch in text:
            sym = Gdk.unicode_to_keyval(ord(ch))
            self.keysym(sym, True)
            self.keysym(sym, False)


def read_secret(name):
    """secrets.env (export NAME=value の形) から値を読む。sentry-api.sh と同じく、
    秘密を会話やプロセスの引数に出さないためにスクリプトの中で読む。"""
    import os
    import re

    path = os.environ.get("CAPSICUM_SECRETS",
                          os.path.expanduser("~/.config/capsicum/secrets.env"))
    pattern = re.compile(r"^(?:export\s+)?" + re.escape(name) + r"=(.*)$")
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pattern.match(line.rstrip("\n"))
            if m:
                value = m.group(1).strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                    value = value[1:-1]
                return value
    raise SystemExit(f"{name} is not in {path}")


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    op, args = argv[1], argv[2:]
    s = Session()
    try:
        if op == "click":
            s.click(args[0], args[1], args[2] if len(args) > 2 else "left")
        elif op == "dclick":
            s.click(args[0], args[1], times=2)
        elif op == "move":
            s.move(args[0], args[1])
        elif op == "drag":
            # ツールキットのドラッグ開始の判定 (押したまま閾値を超えて動く) に
            # 掛かるよう、押した直後は小刻みに動かし、落とす先では少し止まる。
            x1, y1, x2, y2 = (float(a) for a in args[:4])
            s.move(x1, y1)
            s.button("left", True)
            time.sleep(0.2)
            for d in (2, 4, 8, 16):
                s.move(x1 + d, y1 + d)
                time.sleep(0.1)
            steps = 40
            for i in range(1, steps + 1):
                s.move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
                time.sleep(0.03)
            time.sleep(0.6)
            s.button("left", False)
        elif op == "scroll":
            s.move(args[0], args[1])
            s._rd("NotifyPointerAxisDiscrete", "(ui)", 0, int(args[2]))
        elif op == "type":
            s.type(" ".join(args))
        elif op == "type-secret":
            s.type(read_secret(args[0]))
        elif op == "key":
            for spec in args:
                s.combo(spec)
        else:
            raise SystemExit(f"unknown op: {op}\n{__doc__}")
        time.sleep(0.2)
    finally:
        s.stop()


if __name__ == "__main__":
    main(sys.argv)
