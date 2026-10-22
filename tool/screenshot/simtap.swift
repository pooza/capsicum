// 画面座標へマウスの左クリック（またはドラッグ）を CGEvent で送る。
// 使い方:
//   simtap tap  <x> <y>
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
    let mods = args.count >= 4 ? args[3].split(separator: ",") : []
    for m in mods {
        switch m {
        case "fn": flags.insert(.maskSecondaryFn)
        case "ctrl": flags.insert(.maskControl)
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        default: break
        }
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    exit(0)
}
guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else {
    print("usage: simtap tap <x> <y> | drag <x1> <y1> <x2> <y2> [steps]")
    exit(2)
}
let start = CGPoint(x: x, y: y)
switch args[1] {
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
