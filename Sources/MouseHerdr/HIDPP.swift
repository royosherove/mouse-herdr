import Foundation
import IOKit
import IOKit.hid

/// Talks Logitech's HID++ 2.0 protocol to a Bluetooth mouse so the buttons macOS
/// never sees (gesture, top button, haptic panel) can be captured.
final class HIDPP {
    struct Control {
        let cid: UInt16
        let tid: UInt16
        let flags: UInt8
        let flags2: UInt8
        var divertable: Bool { flags & 0x20 != 0 }
        var isVirtual: Bool { flags & 0x80 != 0 }
        var rawXY: Bool { flags2 & 0x01 != 0 }
    }

    enum Status: Equatable { case searching, notPermitted, connected, failed }

    // All callbacks are delivered on the main thread.
    var onStatus: ((Status) -> Void)?
    var onDevice: ((String, Int, [Control]) -> Void)?   // name, HID product id, controls
    var onButtons: ((Set<UInt16>) -> Void)?
    var onRawXY: ((Int, Int) -> Void)?
    var onBattery: ((Int, Bool) -> Void)?
    var onHaptics: ((Bool) -> Void)?

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var responses: [[UInt8]] = []
    private var busy = false
    private var pending: [() -> Void] = []

    private let swid: UInt8 = 0x07
    private var devIdx: UInt8 = 0xFF
    private var rcIdx: UInt8?
    private var batteryIdx: UInt8?
    private var wirelessIdx: UInt8?
    private var hapticIdx: UInt8?
    private var hapticMask: UInt32 = 0
    private var hapticLevel: Int?          // nil = leave the mouse's own setting alone
    private var lastHaptic = Date.distantPast
    private var loggedHaptic = false
    private var desired: [UInt16: Bool] = [:]   // cid → wants raw XY; absent = leave native
    private var managed: [UInt16] = []

    // MARK: Lifecycle

    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            self.openManager()
            ready.signal()
            while true { CFRunLoopRunInMode(.defaultMode, 60, false) }
        }
        t.name = "MouseHerdr.HID"
        t.start()
        thread = t
        ready.wait()
    }

    /// Throw away the connection and look for the mouse again.
    func restart() {
        enqueue { [self] in
            closeManager()
            openManager()
        }
    }

    /// Which controls to capture. Anything in `managed` but not in `diverts` is handed back to the mouse.
    func setDiversions(_ diverts: [UInt16: Bool], managed: [UInt16]) {
        enqueue { [self] in
            desired = diverts
            self.managed = managed
            applyDiversions()
        }
    }

    func reapply() { enqueue { [self] in applyDiversions() } }

    /// Play one of the mouse's built-in haptic waveforms.
    func haptic(_ waveform: UInt8) {
        enqueue { [self] in
            guard let h = hapticIdx, device != nil else { return }
            guard Date().timeIntervalSince(lastHaptic) > 0.045 else { return }   // don't flood the motor
            lastHaptic = Date()
            var id = waveform
            if hapticMask != 0, id < 32, hapticMask & (1 << UInt32(id)) == 0 { id = 0 }
            let ok = request(h, 4, [id], timeout: 0.25) != nil
            if !ok || !loggedHaptic { loggedHaptic = true; Log.write(String(format: "haptics: play %02x %@", id, ok ? "ok" : "FAILED")) }
        }
    }

    /// Haptic strength, 1–100.
    func setHapticLevel(_ percent: Int) {
        enqueue { [self] in
            hapticLevel = percent
            applyHapticLevel()
        }
    }

    private func applyHapticLevel() {
        guard let h = hapticIdx, let level = hapticLevel, device != nil else { return }
        let ok = request(h, 2, [1, UInt8(max(1, min(100, level)))]) != nil
        Log.write("haptics: level \(level)% \(ok ? "ok" : "FAILED")")
    }

    /// Give every button back to the mouse (used on quit). Blocks briefly.
    func releaseAll() {
        let done = DispatchSemaphore(value: 0)
        enqueue { [self] in
            desired = [:]
            applyDiversions()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    // MARK: Work queue (HID thread only)

    private func enqueue(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        if CFRunLoopGetCurrent() === rl { submit(block); return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in submit(block) }
        CFRunLoopWakeUp(rl)
    }

    private func submit(_ block: @escaping () -> Void) {
        if busy { pending.append(block); return }
        busy = true
        block()
        while !pending.isEmpty { pending.removeFirst()() }
        busy = false
    }

    private func main(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    // MARK: Device discovery

    private func openManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Logitech devices that expose the HID++ long-report collection used over Bluetooth LE.
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, dev in
            let me = Unmanaged<HIDPP>.fromOpaque(ctx!).takeUnretainedValue()
            me.submit { me.attach(dev) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, dev in
            let me = Unmanaged<HIDPP>.fromOpaque(ctx!).takeUnretainedValue()
            me.submit { me.detach(dev) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.write("hid manager open: \(hex(r))")
        manager = mgr
        main { self.onStatus?(.searching) }
    }

    private func closeManager() {
        if let dev = device { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        rcIdx = nil; batteryIdx = nil; wirelessIdx = nil; hapticIdx = nil
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    private func attach(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Logitech mouse"
        let productID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let open = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.write("found \(product) (product id \(String(format: "0x%04x", productID))), open: \(hex(open))")
        guard open == kIOReturnSuccess else {
            let status: Status = (open == kIOReturnNotPermitted) ? .notPermitted : .failed
            main { self.onStatus?(status) }
            return
        }
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buffer, 64, { ctx, _, _, _, reportID, report, len in
            let me = Unmanaged<HIDPP>.fromOpaque(ctx!).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: len))
            if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            me.received(bytes)
        }, ctx)

        guard handshake() else {
            Log.write("handshake failed")
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
            main { self.onStatus?(.failed) }
            return
        }

        rcIdx = featureIndex(0x1B04)
        batteryIdx = featureIndex(0x1004)
        wirelessIdx = featureIndex(0x1D4B)
        Log.write("features: reprog=\(rcIdx.map(String.init) ?? "-") battery=\(batteryIdx.map(String.init) ?? "-") wireless=\(wirelessIdx.map(String.init) ?? "-")")

        hapticIdx = featureIndex(0x19B0)
        if let h = hapticIdx {
            if let info = request(h, 0), info.count >= 12 {
                hapticMask = UInt32(info[8]) << 24 | UInt32(info[9]) << 16 | UInt32(info[10]) << 8 | UInt32(info[11])
            }
            let level = request(h, 1)
            Log.write(String(format: "haptics: feature index %d, waveforms %08x, level %@", h, hapticMask,
                             level.map { "\($0[4] & 1 == 1 ? "on" : "off") \($0[5])%" } ?? "?"))
            applyHapticLevel()
        } else {
            Log.write("haptics: not offered by this mouse")
        }
        let hasHaptics = hapticIdx != nil
        main { self.onHaptics?(hasHaptics) }

        let name = readName() ?? product
        let controls = readControls()
        for c in controls {
            Log.write(String(format: "control cid=0x%04x tid=0x%04x flags=%02x flags2=%02x", c.cid, c.tid, c.flags, c.flags2))
        }
        main {
            self.onStatus?(.connected)
            self.onDevice?(name, productID, controls)
        }
        readBattery()
        applyDiversions()
    }

    private func detach(_ dev: IOHIDDevice) {
        guard let current = device, current === dev else { return }
        Log.write("mouse disconnected")
        device = nil
        rcIdx = nil; batteryIdx = nil; wirelessIdx = nil; hapticIdx = nil
        main { self.onStatus?(.searching) }
    }

    // MARK: Protocol

    private func handshake() -> Bool {
        for idx in [UInt8(0xFF), 0x01, 0x00] {
            devIdx = idx
            if let r = request(0x00, 1, [0, 0, 0x5A], timeout: 0.7), r.count > 6, r[6] == 0x5A {
                Log.write("HID++ \(r[4]).\(r[5]) at device index \(hex8(idx))")
                return true
            }
            if device == nil { return false }
        }
        return false
    }

    private func featureIndex(_ id: UInt16) -> UInt8? {
        guard let r = request(0x00, 0, [UInt8(id >> 8), UInt8(id & 0xFF)]), r.count > 4, r[4] != 0 else { return nil }
        return r[4]
    }

    private func readName() -> String? {
        guard let f = featureIndex(0x0005), let l = request(f, 0), l.count > 4 else { return nil }
        let total = Int(l[4])
        var bytes: [UInt8] = []
        while bytes.count < total {
            guard let chunk = request(f, 1, [UInt8(bytes.count)]), chunk.count > 4 else { break }
            bytes += chunk[4...]
        }
        let s = String(bytes: bytes.prefix(total), encoding: .utf8)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private func readControls() -> [Control] {
        guard let rc = rcIdx, let c = request(rc, 0), c.count > 4 else { return [] }
        var out: [Control] = []
        for i in 0..<c[4] {
            guard let info = request(rc, 1, [i]), info.count > 12 else { continue }
            out.append(Control(
                cid: UInt16(info[4]) << 8 | UInt16(info[5]),
                tid: UInt16(info[6]) << 8 | UInt16(info[7]),
                flags: info[8], flags2: info[12]))
        }
        return out
    }

    private func readBattery() {
        guard let b = batteryIdx, let s = request(b, 1), s.count > 6 else { return }
        report(battery: s)
    }

    private func report(battery r: [UInt8]) {
        let percent = Int(r[4]), charging = (1...3).contains(r[6])
        main { self.onBattery?(percent, charging) }
    }

    private func applyDiversions() {
        guard device != nil, let rc = rcIdx else { return }
        for cid in managed {
            let flags: UInt8
            if let raw = desired[cid] {
                flags = raw ? 0x33 : 0x23          // divert on; raw XY on or off
            } else {
                flags = 0x22                        // divert off, raw XY off
            }
            let ok = request(rc, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0]) != nil
            Log.write(String(format: "divert cid=0x%04x flags=%02x %@", cid, flags, ok ? "ok" : "FAILED"))
        }
    }

    private func request(_ feat: UInt8, _ fn: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 1.5) -> [UInt8]? {
        guard let dev = device else { return nil }
        var msg = [UInt8](repeating: 0, count: 20)
        msg[0] = 0x11; msg[1] = devIdx; msg[2] = feat; msg[3] = (fn << 4) | swid
        for (i, p) in params.prefix(16).enumerated() { msg[4 + i] = p }
        responses.removeAll()
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, msg, msg.count)
        guard r == kIOReturnSuccess else { Log.write("send failed: \(hex(r))"); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, device != nil {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            for resp in responses where resp.count >= 5 {
                if resp[2] == feat && resp[3] == msg[3] { return resp }
                if resp[2] == 0xFF && resp[3] == feat && resp[4] == msg[3] {
                    Log.write("HID++ error \(resp.count > 5 ? resp[5] : 0) for feature index \(feat) fn \(fn)")
                    return nil
                }
            }
        }
        Log.write("timeout for feature index \(feat) fn \(fn)")
        return nil
    }

    private func received(_ b: [UInt8]) {
        guard b.count >= 7, b[0] == 0x11 || b[0] == 0x10 else { return }
        let isEvent = (b[3] & 0x0F) == 0 && b[2] != 0xFF
        guard isEvent else { responses.append(b); return }
        let fn = b[3] >> 4
        if let rc = rcIdx, b[2] == rc {
            if fn == 0, b.count >= 12 {
                var cids = Set<UInt16>()
                for i in stride(from: 4, to: 12, by: 2) {
                    let cid = UInt16(b[i]) << 8 | UInt16(b[i + 1])
                    if cid != 0 { cids.insert(cid) }
                }
                main { self.onButtons?(cids) }
            } else if fn == 1, b.count >= 8 {
                let dx = Int(Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5])))
                let dy = Int(Int16(bitPattern: UInt16(b[6]) << 8 | UInt16(b[7])))
                main { self.onRawXY?(dx, dy) }
            }
        } else if let bi = batteryIdx, b[2] == bi, fn == 0 {
            report(battery: b)
        } else if let wi = wirelessIdx, b[2] == wi {
            // The mouse reconnected and forgot its settings — tell it again.
            Log.write("mouse reconnected, re-applying")
            submit { [self] in applyDiversions(); applyHapticLevel() }
        }
    }

    private func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }
    private func hex8(_ v: UInt8) -> String { String(format: "0x%02x", v) }
}
