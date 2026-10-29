// VolumeControl.swift
// Menu bar app для керування гучністю Multi-Output / Aggregate пристрою на macOS.
//
// Замінює штатний регулятор звуку, який macOS блокує для об'єднаних виходів:
//   • Перехоплює фізичні клавіші гучності (F10 Mute / F11 − / F12 +) через CGEventTap
//     і застосовує зміну до всіх субпристроїв об'єднаного виходу.
//   • Показує % з іконкою в рядку меню + повзунок.
//   • У меню — список пристроїв виводу з перемиканням (як штатне меню «Звук»)
//     та пункт відкриття налаштувань звуку.
//   • OSD-оверлей (напівпрозорий HUD) при кожній зміні.
//   • Резервні горячі клавіші ⌃⌥↑ / ⌃⌥↓ (працюють без дозволів).
//
// Перехоплення фізичних клавіш потребує одноразового дозволу Accessibility.
// Збірка: дивись build.sh

import Cocoa
import CoreAudio
import AudioToolbox
import CoreGraphics
import ApplicationServices
import Carbon
import Carbon.HIToolbox

// MARK: - CoreAudio helpers

/// Поточний системний output-пристрій (може бути агрегатом / Multi-Output).
func defaultOutputDevice() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, &size, &deviceID)
    return deviceID
}

/// Встановлює системний output-пристрій.
func setDefaultOutputDevice(_ id: AudioDeviceID) {
    var dev = id
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, size, &dev)
}

/// Усі пристрої, що мають output-канали.
func allOutputDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { hasOutputStreams($0) }
}

/// Чи має пристрій хоч один output-потік.
func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let st = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    return st == noErr && size > 0
}

/// Активні субпристрої агрегату. Для звичайного пристрою повертає [].
func subDevices(of device: AudioDeviceID) -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    let sizeStatus = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
    guard sizeStatus == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var subs = [AudioObjectID](repeating: 0, count: count)
    let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &subs)
    guard status == noErr else { return [] }
    return subs
}

/// Читає гучність (0.0...1.0). Спершу master-елемент, потім усереднює канали 1/2.
func getVolume(_ device: AudioDeviceID) -> Float? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain) // master

    if AudioObjectHasProperty(device, &addr) {
        var vol = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
            return vol
        }
    }

    var total: Float = 0
    var n = 0
    for ch in [UInt32(1), UInt32(2)] {
        addr.mElement = ch
        if AudioObjectHasProperty(device, &addr) {
            var v = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr {
                total += v
                n += 1
            }
        }
    }
    return n > 0 ? total / Float(n) : nil
}

/// Ставить гучність (0.0...1.0). Спершу master, якщо не settable — по каналах.
func setVolume(_ device: AudioDeviceID, _ value: Float) {
    let v = max(0, min(1, value))
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    let size = UInt32(MemoryLayout<Float>.size)

    var settable = DarwinBoolean(false)
    if AudioObjectHasProperty(device, &addr),
       AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
       settable.boolValue {
        var vol = v
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &vol)
        return
    }

    for ch in [UInt32(1), UInt32(2)] {
        addr.mElement = ch
        var s = DarwinBoolean(false)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectIsPropertySettable(device, &addr, &s) == noErr,
           s.boolValue {
            var vol = v
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, &vol)
        }
    }
}

/// Людська назва пристрою.
func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var name: CFString? = nil
    let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
    if status == noErr, let n = name { return n as String }
    return "Пристрій"
}

// MARK: - OSD оверлей

final class OSDView: NSView {
    var level: Int = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()

        let symbolName = level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            let icon = base.withSymbolConfiguration(cfg) ?? base
            let side: CGFloat = 36
            let r = NSRect(x: (bounds.width - side) / 2,
                           y: bounds.height - side - 26,
                           width: side, height: side)
            icon.draw(in: r)
        }

        let trackW = bounds.width - 48
        let trackX = (bounds.width - trackW) / 2
        let trackY: CGFloat = 46
        let trackH: CGFloat = 8
        NSColor(white: 1, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: trackX, y: trackY, width: trackW, height: trackH),
                     xRadius: 4, yRadius: 4).fill()
        let fillW = max(0, trackW * CGFloat(level) / 100.0)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: trackX, y: trackY, width: fillW, height: trackH),
                     xRadius: 4, yRadius: 4).fill()

        let text = "\(level)%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 16), withAttributes: attrs)
    }
}

final class OSD {
    private var window: NSWindow?
    private var osdView: OSDView?
    private var hideWork: DispatchWorkItem?
    private let sideLen: CGFloat = 200

    func show(level: Int) {
        if window == nil { build() }
        guard let window = window, let osdView = osdView else { return }

        osdView.level = level
        osdView.needsDisplay = true

        hideWork?.cancel()
        window.alphaValue = 1
        positionWindow(window)
        window.orderFrontRegardless()

        let work = DispatchWorkItem { [weak window] in
            guard let window = window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: sideLen, height: sideLen)
        let w = NSWindow(contentRect: rect, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: rect)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let view = OSDView(frame: rect)
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)

        w.contentView = blur
        window = w
        osdView = view
    }

    private func positionWindow(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.frame else { return }
        let x = f.midX - sideLen / 2
        let y = f.minY + 140
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Перехоплення медіа-клавіш (CGEventTap)

// Коди спец-клавіш звуку (NX_KEYTYPE_*):
let kSoundUp   = 0
let kSoundDown = 1
let kMute      = 7

var gEventTap: CFMachPort?

/// C-колбек для подій медіа-клавіш (NX_SYSDEFINED == 14).
func mediaKeyCallback(proxy: CGEventTapProxy,
                      type: CGEventType,
                      event: CGEvent,
                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // Якщо систему вимкнула тап — ввімкнути назад.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == 14 else { return Unmanaged.passUnretained(event) }
    guard let ns = NSEvent(cgEvent: event),
          ns.type == .systemDefined,
          ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = ns.data1
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = data1 & 0x0000FFFF
    let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

    if keyCode == kSoundUp || keyCode == kSoundDown || keyCode == kMute {
        if keyDown {
            let kc = Int(keyCode)
            DispatchQueue.main.async { appController?.handleMediaKey(code: kc) }
        }
        return nil // поглинаємо, щоб штатна поведінка не спрацьовувала
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Горячі клавіші (Carbon, резерв без дозволів)

let gHotKeySignature: OSType = 0x56434B31 // 'VCK1'
weak var appController: AppDelegate?

func hotKeyHandler(_ nextHandler: EventHandlerCallRef?,
                   _ theEvent: EventRef?,
                   _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let theEvent = theEvent else { return noErr }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(theEvent,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hkID)
    if status == noErr {
        let id = hkID.id
        DispatchQueue.main.async { appController?.handleHotKey(id: id) }
    }
    return noErr
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let osd = OSD()
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var retryTimer: Timer?
    private var mediaKeysActive = false
    private var lastNonZero: Float = 0.5
    private let step = 10 // крок зміни у відсотках

    func applicationDidFinishLaunching(_ notification: Notification) {
        appController = self
        setupMenuBar()
        setupHotKeys()
        enableMediaKeys()
        refreshFromSystem()
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Гучність") {
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageLeading
        }
        statusItem.button?.title = " —%"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Меню перебудовується щоразу при відкритті — щоб список пристроїв був актуальним.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let targets = currentTargets()
        let pct = Int((currentAverage(targets) * 100).rounded())

        // Повзунок
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        let slider = NSSlider(value: Double(pct), minValue: 0, maxValue: 100,
                              target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 16, y: 10, width: 208, height: 24)
        slider.isContinuous = true
        container.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = container
        menu.addItem(sliderItem)

        let names = targets.map { deviceName($0) }.joined(separator: ", ")
        let info = NSMenuItem(title: "Керує: \(names)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        menu.addItem(.separator())
        menu.addItem(makeItem("Гучність +\(step)   (F12)", #selector(volumeUp)))
        menu.addItem(makeItem("Гучність −\(step)   (F11)", #selector(volumeDown)))
        menu.addItem(makeItem("Без звуку   (F10)", #selector(toggleMuteAction)))

        // Вибір пристрою виводу
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Вихід звуку:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let currentDefault = defaultOutputDevice()
        for dev in allOutputDevices() {
            let item = makeItem(deviceName(dev), #selector(selectDevice(_:)))
            item.representedObject = NSNumber(value: dev)
            item.state = (dev == currentDefault) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Налаштування звуку…", #selector(openSoundSettings)))
        if !mediaKeysActive {
            menu.addItem(makeItem("⚠︎ Дозволити клавіші гучності…", #selector(openAccessibility)))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateUI(_ pct: Int) {
        statusItem.button?.title = " \(pct)%"
    }

    // MARK: Дії

    @objc private func volumeUp() { change(by: step) }
    @objc private func volumeDown() { change(by: -step) }
    @objc private func toggleMuteAction() { toggleMute() }

    @objc private func sliderMoved(_ s: NSSlider) {
        let pct = Int(s.doubleValue.rounded())
        let targets = currentTargets()
        let v = Float(pct) / 100.0
        for d in targets { setVolume(d, v) }
        updateUI(pct)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        setDefaultOutputDevice(AudioDeviceID(num.uint32Value))
        refreshFromSystem()
    }

    @objc private func openSoundSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound"
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func openAccessibility() {
        promptAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func handleHotKey(id: UInt32) {
        if id == 1 { change(by: step) }
        else if id == 2 { change(by: -step) }
    }

    func handleMediaKey(code: Int) {
        switch code {
        case kSoundUp:   change(by: step)
        case kSoundDown: change(by: -step)
        case kMute:      toggleMute()
        default: break
        }
    }

    private func change(by delta: Int) {
        let targets = currentTargets()
        let d = Float(delta) / 100.0
        // Кожен субпристрій змінюємо від ЙОГО власного рівня, щоб зберегти баланс.
        var newLevels: [Float] = []
        for dev in targets {
            guard let cur = getVolume(dev) else { continue }
            let nv = min(1, max(0, cur + d))
            setVolume(dev, nv)
            newLevels.append(nv)
        }
        let avg = newLevels.isEmpty
            ? currentAverage(targets)
            : newLevels.reduce(0, +) / Float(newLevels.count)
        let pct = Int((avg * 100).rounded())
        updateUI(pct)
        osd.show(level: pct)
    }

    private func toggleMute() {
        let targets = currentTargets()
        let cur = currentAverage(targets)
        if cur > 0.001 {
            lastNonZero = cur
            for d in targets { setVolume(d, 0) }
            updateUI(0)
            osd.show(level: 0)
        } else {
            for d in targets { setVolume(d, lastNonZero) }
            let pct = Int((lastNonZero * 100).rounded())
            updateUI(pct)
            osd.show(level: pct)
        }
    }

    private func refreshFromSystem() {
        let targets = currentTargets()
        let pct = Int((currentAverage(targets) * 100).rounded())
        updateUI(pct)
    }

    // MARK: Пристрої

    private func currentTargets() -> [AudioDeviceID] {
        let dev = defaultOutputDevice()
        let subs = subDevices(of: dev)
        return subs.isEmpty ? [dev] : subs
    }

    private func currentAverage(_ targets: [AudioDeviceID]) -> Float {
        var sum: Float = 0
        var n = 0
        for d in targets {
            if let v = getVolume(d) { sum += v; n += 1 }
        }
        return n > 0 ? sum / Float(n) : 0.5
    }

    // MARK: Медіа-клавіші (CGEventTap)

    private func enableMediaKeys() {
        if createEventTap() { mediaKeysActive = true; return }
        // Немає дозволу — показати запит і періодично пробувати.
        promptAccessibility()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.createEventTap() {
                self.mediaKeysActive = true
                t.invalidate()
            }
        }
    }

    private func createEventTap() -> Bool {
        if gEventTap != nil { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: mediaKeyCallback,
                                          userInfo: nil) else {
            return false
        }
        gEventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func promptAccessibility() {
        // Ключ = значення kAXTrustedCheckOptionPrompt (уникаємо розбіжностей SDK).
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Горячі клавіші (Carbon)

    private func setupHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        register(keyCode: kVK_UpArrow, id: 1)
        register(keyCode: kVK_DownArrow, id: 2)
    }

    private func register(keyCode: Int, id: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: gHotKeySignature, id: id)
        let mods = UInt32(controlKey | optionKey)
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRefs.append(ref) }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без іконки в Dock
app.run()
