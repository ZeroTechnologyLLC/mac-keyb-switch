import Carbon
import AppKit
import Foundation

// layoutd — instant keyboard layout switching via Cmd+Space.
//
// Problem: the stock "Input Sources" hotkey (Cmd+Space) in macOS switches the
// layout on key RELEASE and drops 10–30% of presses under CPU load (a bug in
// the symbolic hotkey → WindowServer → TextInputMenuAgent chain).
//
// Solution: an active CGEventTap intercepts Cmd+Space before the system and
// calls TISSelectInputSource directly on keyDown (the machinery runs in 2–9 ms).
// Both keyDown and keyUp are swallowed so the system hotkey never fires.

let VERSION = "2.0"

// MARK: - Configuration

struct Config {
    var first: String = "com.apple.keylayout.US"
    var second: String = "com.apple.keylayout.Russian"
    var debug: Bool = false
}

func printUsage() {
    let prog = CommandLine.arguments[0].components(separatedBy: "/").last ?? "layoutd"
    print("""
    layoutd \(VERSION) — instant keyboard layout switching via Cmd+Space

    Usage:
      \(prog) [options]

    Options:
      --first <id>    first input source    (default: com.apple.keylayout.US)
      --second <id>   second input source   (default: com.apple.keylayout.Russian)
      --debug         verbose logging of all Space events (diagnostics)
      --list          print available input sources and exit
      --help          this help

    Requires the Accessibility permission (System Settings → Privacy & Security
    → Accessibility) for this binary.
    """)
}

func parseArgs() -> Config {
    var cfg = Config()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--first":
            if i + 1 < args.count { cfg.first = args[i + 1]; i += 1 }
        case "--second":
            if i + 1 < args.count { cfg.second = args[i + 1]; i += 1 }
        case "--debug":
            cfg.debug = true
        case "--list":
            listInputSources()
            exit(0)
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write("Unknown option: \(args[i])\n".data(using: .utf8)!)
            printUsage()
            exit(1)
        }
        i += 1
    }
    return cfg
}

func listInputSources() {
    let filter: [CFString: Any] = [kTISPropertyInputSourceType: "TISTypeKeyboardLayout" as CFString]
    guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
        print("failed to get the input source list"); return
    }
    print("Available keyboard layouts (Input Source ID):")
    for src in list {
        if let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            var name = ""
            if let namePtr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
                name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
            }
            let sel = (TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelected) != nil)
            print("  \(id)  (\(name))\(sel ? "  <- current" : "")")
        }
    }
}

// MARK: - State (static: a C callback cannot capture context)

final class LayoutState {
    static var firstSource: TISInputSource?
    static var secondSource: TISInputSource?
    static var firstID = ""
    static var secondID = ""
    static var debug = false
    static var switchCount = 0
    static var tap: CFMachPort?
    static var isDown = false
    static var lastSpaceUp: DispatchTime?   // processing time of the last Space keyUp
    static var lastSwitch: DispatchTime?    // time of the last switch (cooldown)
}

func findSource(_ id: String) -> TISInputSource? {
    let filter: [CFString: Any] = [kTISPropertyInputSourceID: id]
    guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
    return list.first
}

func currentLayoutID() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "?" }
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func log(_ msg: String) {
    print(msg)
    fflush(stdout)
}

// MARK: - Event tap

func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout {
        if let tap = LayoutState.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }
    if type == .tapDisabledByUserInput { return Unmanaged.passRetained(event) }

    // Diagnostics: raw Space event stream (--debug only)
    if LayoutState.debug, type == .keyDown || type == .keyUp {
        if event.getIntegerValueField(.keyboardEventKeycode) == 49 {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let t = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
            log(String(format: "[dbg] %.1fms %@ Space autorepeat=%d cmd=%d evts=%llu",
                        t, type == .keyDown ? "DOWN" : "UP",
                        isRepeat ? 1 : 0,
                        event.flags.contains(.maskCommand) ? 1 : 0,
                        event.timestamp))
        }
    }

    // Reset isDown — BEFORE the flag guard:
    // (1) any Space keyUp (even without Cmd — the user released Cmd before Space);
    if type == .keyUp && event.getIntegerValueField(.keyboardEventKeycode) == 49 {
        LayoutState.lastSpaceUp = DispatchTime.now()
        if LayoutState.isDown {
            LayoutState.isDown = false
        }
    }
    // (2) Cmd release (flagsChanged, the Command flag is gone) — the press is over.
    if type == .flagsChanged {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if (kc == 54 || kc == 55) && !event.flags.contains(.maskCommand) {
            if LayoutState.isDown {
                LayoutState.isDown = false
            }
        }
        return Unmanaged.passRetained(event) // do not swallow flagsChanged
    }

    guard type == .keyDown || type == .keyUp else { return Unmanaged.passRetained(event) }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    // Space (49) + exactly Command (no option/ctrl/shift)
    guard keyCode == 49,
          flags.contains(.maskCommand),
          !flags.contains(.maskAlternate),
          !flags.contains(.maskControl),
          !flags.contains(.maskShift) else {
        return Unmanaged.passRetained(event)
    }

    if type == .keyDown {
        if LayoutState.isDown { return nil }  // auto-repeat — ignore
        // Deduplication (two layers):
        // (a) a DOWN arriving <40 ms after a Space UP is a system-duplicated
        //     UP+DOWN pair (under load macOS 27 duplicates events 0.0–0.2 ms
        //     apart; a human physically cannot press again within ~50 ms);
        // (b) a DOWN arriving <60 ms after the last switch is a duplicate
        //     following a long press (a double switch = back to the original).
        if let lastUp = LayoutState.lastSpaceUp {
            let sinceUpMs = Double(DispatchTime.now().uptimeNanoseconds - lastUp.uptimeNanoseconds) / 1_000_000
            if sinceUpMs < 40 {
                log(String(format: "[layoutd] dup suppressed: DOWN %.1f ms after UP", sinceUpMs))
                return nil
            }
        }
        if let lastSw = LayoutState.lastSwitch {
            let sinceSwMs = Double(DispatchTime.now().uptimeNanoseconds - lastSw.uptimeNanoseconds) / 1_000_000
            if sinceSwMs < 60 {
                log(String(format: "[layoutd] dup suppressed: DOWN %.1f ms after switch (cooldown)", sinceSwMs))
                return nil
            }
        }
        LayoutState.isDown = true
        let before = currentLayoutID()
        let target = (before == LayoutState.secondID) ? LayoutState.firstSource : LayoutState.secondSource
        let tSwitch = DispatchTime.now()
        if let target = target {
            TISSelectInputSource(target)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - tSwitch.uptimeNanoseconds) / 1_000_000
            LayoutState.lastSwitch = DispatchTime.now()
            LayoutState.switchCount += 1
            log(String(format: "[layoutd] switch #%d on keyDown: TISSelect=%.1f ms (%@ -> %@)",
                       LayoutState.switchCount, ms, before, currentLayoutID()))
        }
    }
    // Swallow both keyDown and keyUp (Cmd+Space) — the system hotkey won't fire
    return nil
}

// MARK: - main

let cfg = parseArgs()

guard let first = findSource(cfg.first) else {
    FileHandle.standardError.write("FATAL: input source not found: \(cfg.first)\n".data(using: .utf8)!)
    FileHandle.standardError.write("Run with --list to see the available sources\n".data(using: .utf8)!)
    exit(1)
}
guard let second = findSource(cfg.second) else {
    FileHandle.standardError.write("FATAL: input source not found: \(cfg.second)\n".data(using: .utf8)!)
    FileHandle.standardError.write("Run with --list to see the available sources\n".data(using: .utf8)!)
    exit(1)
}
LayoutState.firstSource = first
LayoutState.secondSource = second
LayoutState.firstID = cfg.first
LayoutState.secondID = cfg.second
LayoutState.debug = cfg.debug

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                      | (1 << CGEventType.keyUp.rawValue)
                      | (1 << CGEventType.flagsChanged.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: eventCallback,
    userInfo: nil
) else {
    FileHandle.standardError.write("FATAL: cannot create event tap — Accessibility permission required\n".data(using: .utf8)!)
    FileHandle.standardError.write("System Settings → Privacy & Security → Accessibility → add this binary\n".data(using: .utf8)!)
    exit(1)
}
LayoutState.tap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

log("[layoutd] started v\(VERSION) — Cmd+Space -> TISSelectInputSource on keyDown")
log("[layoutd] layouts: \(cfg.first) <-> \(cfg.second), current: \(currentLayoutID())")

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

CFRunLoopRun()
