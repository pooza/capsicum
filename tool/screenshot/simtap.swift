// 画面座標へマウスの左クリック（またはドラッグ）を CGEvent で送る。
// 使い方:
//   simtap tap  <x> <y>
//   simtap move <x> <y> [<x2> <y2> [steps]]
//   simtap drag <x1> <y1> <x2> <y2> [steps]
import CoreGraphics
import Foundation

func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
}

let args = CommandLine.arguments
// simtap key <keycode> <fn|ctrl|cmd|shift|opt をカンマ区切り>
if args.count >= 3 && args[1] == "key", let code = UInt16(args[2]) {
    var flags: CGEventFlags = []
    // ⚠ 修飾キーは、キー自体の押し下げ・離しも送る。フラグを付けるだけだと
    // DeviceHub（シミュレータ）が修飾として拾わず、⌘F が「f」の入力になる
    // （2026-10-25・#1268 で踏んだ）。
    var modifierKeys: [(CGKeyCode, CGEventFlags)] = []
    let mods = args.count >= 4 ? args[3].split(separator: ",") : []
    for m in mods {
        switch m {
        case "fn": flags.insert(.maskSecondaryFn); modifierKeys.append((63, .maskSecondaryFn))
        case "ctrl": flags.insert(.maskControl); modifierKeys.append((59, .maskControl))
        case "cmd": flags.insert(.maskCommand); modifierKeys.append((55, .maskCommand))
        case "shift": flags.insert(.maskShift); modifierKeys.append((56, .maskShift))
        case "opt": flags.insert(.maskAlternate); modifierKeys.append((58, .maskAlternate))
        default: break
        }
    }
    var held: CGEventFlags = []
    for (key, flag) in modifierKeys {
        held.insert(flag)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        e?.flags = held
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    for (key, flag) in modifierKeys.reversed() {
        held.remove(flag)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        e?.flags = held
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    exit(0)
}
guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else {
    print("usage: simtap tap <x> <y> | drag <x1> <y1> <x2> <y2> [steps]")
    exit(2)
}
let start = CGPoint(x: x, y: y)
switch args[1] {
case "move":
    // 押さずに動かすだけ。終点を渡すとそこまで滑らせる（iPad の上端へ押し付けると
    // メニューバーが出る）。
    post(.mouseMoved, start)
    if args.count >= 6, let x2 = Double(args[4]), let y2 = Double(args[5]) {
        let steps = args.count >= 7 ? Int(args[6]) ?? 20 : 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            usleep(30_000)
            post(.mouseMoved, CGPoint(x: x + (x2 - x) * t, y: y + (y2 - y) * t))
        }
    }
case "tap":
    post(.mouseMoved, start)
    usleep(50_000)
    post(.leftMouseDown, start)
    usleep(80_000)
    post(.leftMouseUp, start)
case "drag":
    guard args.count >= 6, let x2 = Double(args[4]), let y2 = Double(args[5]) else { exit(2) }
    let steps = args.count >= 7 ? Int(args[6]) ?? 20 : 20
    post(.mouseMoved, start)
    usleep(50_000)
    post(.leftMouseDown, start)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: x + (x2 - x) * t, y: y + (y2 - y) * t))
        usleep(16_000)
    }
    post(.leftMouseUp, CGPoint(x: x2, y: y2))
default:
    exit(2)
}
