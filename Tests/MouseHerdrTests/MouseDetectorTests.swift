import XCTest
@testable import MouseHerdr

final class MouseDetectorTests: XCTestCase {
    // What the Mac this was developed on reports, as read without opening any device.
    private let mx4 = MouseDevice(vendorID: 0x046D, productID: 0xB042, name: "MX Master 4", maker: "Logitech",
                                  transport: "Bluetooth Low Energy", buttons: 7)
    private let microsoft = MouseDevice(vendorID: 0x045E, productID: 0x00CB, name: "Microsoft USB Optical Mouse", maker: "PixArt",
                                        transport: "USB", buttons: 3)
    private let receiver = MouseDevice(vendorID: 0x046D, productID: 0xC52B, name: "USB Receiver", maker: "Logitech",
                                       transport: "USB", buttons: 16)
    private let trackpad = MouseDevice(name: "Apple Internal Keyboard / Trackpad", maker: "Apple", transport: "FIFO",
                                       builtIn: true, buttons: 3, touchPad: true)
    // Other things a Mac can have.
    private let razer = MouseDevice(vendorID: 0x1532, productID: 0x0084, name: "Razer DeathAdder V2", transport: "USB", buttons: 5)
    private let unknown = MouseDevice(vendorID: 0x1BCF, productID: 0x0005, name: "USB Optical Mouse", transport: "USB", buttons: 3)

    // MARK: What counts as a mouse

    func testTrackpadsTabletsAndVirtualDevicesAreNotMice() {
        let notMice = [
            trackpad,
            MouseDevice(vendorID: 0x004C, productID: 0x0265, name: "Magic Trackpad", transport: "Bluetooth"),
            MouseDevice(vendorID: 0x16C0, productID: 0x27DA, name: "Karabiner DriverKit VirtualHIDPointing 1.8.0", transport: "Virtual"),
            MouseDevice(vendorID: 0x056A, productID: 0x0374, name: "Intuos S Pen Tablet", transport: "USB"),
            MouseDevice(vendorID: 0x3434, productID: 0x0220, name: "Keychron K2 Keyboard", transport: "USB", keyboard: true, mouseFirst: false),
            MouseDevice(vendorID: 0x1234, productID: 0x0001, name: "Precision Touchpad", transport: "USB", touchPad: true),
        ]
        for device in notMice {
            XCTAssertEqual(device.kind, .ignored, device.name)
            XCTAssertEqual(MouseChooser.tier(device), -1, device.name)
        }
        XCTAssertTrue(MouseChooser.candidates(notMice).isEmpty)
        XCTAssertNil(MouseChooser.active(among: MouseChooser.candidates(notMice), pinned: nil))
    }

    func testReceiversAreKeptApartFromMice() {
        XCTAssertEqual(receiver.kind, .receiver)
        XCTAssertEqual(MouseDevice(vendorID: 0x045E, productID: 0x07A5, name: "Microsoft® 2.4GHz Transceiver v9.0").kind, .receiver)
        // One nobody has listed is still spotted by what it calls itself.
        XCTAssertEqual(MouseDevice(vendorID: 0x1234, productID: 0x0001, name: "2.4G Wireless Receiver").kind, .receiver)
        // Something that is a keyboard first and a mouse second may or may not have a mouse on it.
        XCTAssertEqual(MouseDevice(vendorID: 0x1234, productID: 0x0002, name: "Wireless Combo", keyboard: true, mouseFirst: false).kind, .receiver)
        XCTAssertEqual(mx4.kind, .mouse)
        XCTAssertEqual(microsoft.kind, .mouse)
        XCTAssertEqual(unknown.kind, .mouse)
    }

    /// Several mice are keyboards too, for a thumb button that types a shortcut: macOS lists the
    /// M720 Triathlon among its keyboards. That must not make a mouse rank as a receiver.
    func testAMouseThatIsAlsoAKeyboardIsStillAMouse() {
        let m720 = MouseDevice(vendorID: 0x046D, productID: 0xB015, name: "M720 Triathlon", transport: "Bluetooth Low Energy",
                               buttons: 8, keyboard: true)
        XCTAssertEqual(m720.kind, .mouse)
        XCTAssertEqual(MouseChooser.tier(m720), 2)
        // It is followed ahead of a mouse nobody knows, and gets its own profile.
        let list = MouseChooser.candidates([unknown, m720])
        XCTAssertEqual(list.first?.key, m720.key)
        XCTAssertEqual(MouseChooser.profile(for: list.first, memory: MouseMemory(), firstRun: true).id, "m720")
        // Even if it said keyboard first, a model in the list is what the list says.
        var keyboardFirst = m720
        keyboardFirst.mouseFirst = false
        XCTAssertEqual(keyboardFirst.kind, .mouse)

        // A gaming mouse nobody has listed, with a keyboard for its macro keys, is a mouse as well.
        let gaming = MouseDevice(vendorID: 0x1234, productID: 0x0009, name: "RGB Gaming Mouse", transport: "USB", buttons: 8, keyboard: true)
        XCTAssertEqual(gaming.kind, .mouse)
        XCTAssertEqual(MouseChooser.tier(gaming), 1)
    }

    func testTheOrderDevicesAreReadInNeverChangesTheAnswer() {
        // One mouse seen as two HID devices: its mouse, and a keyboard that can also point.
        let plain = MouseDevice(vendorID: 0x1234, productID: 0x0009, name: "RGB Gaming Mouse", transport: "USB", buttons: 5)
        var keys = plain
        keys.keyboard = true
        keys.mouseFirst = false
        keys.buttons = 3
        for pair in [[plain, keys], [keys, plain]] {
            let merged = MouseChooser.candidates(pair)
            XCTAssertEqual(merged.count, 1)
            XCTAssertEqual(merged.first?.kind, .mouse, "one of them being a plain mouse is enough")
            XCTAssertEqual(merged.first?.buttons, 5)
        }
        // And the whole list comes out the same however it is shuffled.
        let all = [trackpad, receiver, microsoft, mx4, razer, unknown, plain, keys]
        let expected = MouseChooser.candidates(all)
        for _ in 0..<20 {
            XCTAssertEqual(MouseChooser.candidates(all.shuffled()), expected)
        }
    }

    func testDevicesAreToldApartByTheirIdsOrFailingThatTheirName() {
        XCTAssertEqual(microsoft.key, "045e:00cb")
        XCTAssertEqual(MouseDevice(name: "Some Bluetooth Mouse").key, "name:some bluetooth mouse")
        XCTAssertTrue(mx4.isBluetooth)
        XCTAssertEqual(mx4.connection, "Bluetooth")
        XCTAssertEqual(microsoft.connection, "USB")
        XCTAssertEqual(MouseDevice(name: "Mystery").connection, "connected")
    }

    // MARK: Which mouse is followed

    func testTheDevicesOnTheDevelopmentMacAreRankedWithTheMXMaster4First() {
        let list = MouseChooser.candidates([trackpad, receiver, microsoft, mx4])
        XCTAssertEqual(list.map(\.key), [mx4.key, microsoft.key, receiver.key])
        XCTAssertEqual(list.map(MouseChooser.tier), [3, 2, 0])
        XCTAssertEqual(MouseChooser.active(among: list, pinned: nil), mx4)
    }

    func testWithoutAnMXMaster4TheOtherMouseIsFollowedAndRecognised() {
        let list = MouseChooser.candidates([trackpad, receiver, microsoft])
        let followed = MouseChooser.active(among: list, pinned: nil)
        XCTAssertEqual(followed, microsoft)
        XCTAssertEqual(MouseChooser.profile(for: followed, memory: MouseMemory(), firstRun: true).id, "msBasicOptical")
    }

    func testAReceiverIsFollowedOnlyWhenNoMouseIs() {
        XCTAssertEqual(MouseChooser.active(among: MouseChooser.candidates([receiver, unknown]), pinned: nil), unknown)
        let alone = MouseChooser.active(among: MouseChooser.candidates([trackpad, receiver]), pinned: nil)
        XCTAssertEqual(alone, receiver)
        let profile = MouseChooser.profile(for: alone, memory: MouseMemory(), firstRun: true)
        XCTAssertEqual(profile.id, "logitechReceiver")
        XCTAssertEqual(profile.kind, .receiver)
        XCTAssertEqual(Set(profile.controls.map(\.slot)), [.middle, .back, .forward])
    }

    func testAmongMiceOfTheSameStandingTheOneThatConnectedLastIsFollowed() {
        var first = razer, second = microsoft
        first.order = 1; second.order = 2
        XCTAssertEqual(MouseChooser.candidates([first, second]).first?.key, microsoft.key)
        first.order = 3
        XCTAssertEqual(MouseChooser.candidates([first, second]).first?.key, razer.key)
        // Connecting later does not put an unknown mouse ahead of a recognised one.
        var late = unknown
        late.order = 9
        XCTAssertEqual(MouseChooser.candidates([first, second, late]).first?.key, razer.key)
    }

    func testAMousePickedByHandIsFollowedWhileItIsConnected() {
        let all = MouseChooser.candidates([mx4, microsoft, receiver])
        XCTAssertEqual(MouseChooser.active(among: all, pinned: microsoft.key), microsoft)
        XCTAssertEqual(MouseChooser.active(among: all, pinned: receiver.key), receiver)
        // Unplugged, the choice lapses until it is back.
        let without = MouseChooser.candidates([mx4, receiver])
        XCTAssertEqual(MouseChooser.active(among: without, pinned: microsoft.key), mx4)
    }

    func testAMouseSeenAsSeveralHIDDevicesIsListedOnce() {
        var twin = razer
        twin.buttons = 8
        twin.order = 4
        let list = MouseChooser.candidates([razer, twin, razer])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.buttons, 8)
        XCTAssertEqual(list.first?.order, 4)
    }

    // MARK: Which profile it gets

    func testAnUnknownMouseGetsALayoutForTheButtonsItHas() {
        XCTAssertEqual(MouseChooser.profile(for: unknown, memory: MouseMemory(), firstRun: true).id, "generic3")
        var five = unknown
        five.buttons = 5
        XCTAssertEqual(MouseChooser.profile(for: five, memory: MouseMemory(), firstRun: true).id, "generic")
        five.buttons = 2
        XCTAssertEqual(MouseChooser.profile(for: five, memory: MouseMemory(), firstRun: true).id, "generic2")
    }

    func testAModelPickedByHandIsUsedForThatDeviceAndNoOther() {
        var memory = MouseMemory()
        memory.chosen[receiver.key] = "m720"
        XCTAssertEqual(MouseChooser.profile(for: receiver, memory: memory, firstRun: false).id, "m720")
        XCTAssertEqual(MouseChooser.profile(for: microsoft, memory: memory, firstRun: false).id, "msBasicOptical")
        // A model that no longer exists is forgotten, not shown as nothing.
        memory.chosen[receiver.key] = "noSuchMouse"
        XCTAssertEqual(MouseChooser.profile(for: receiver, memory: memory, firstRun: false).id, "logitechReceiver")
    }

    func testWithNoMouseConnectedTheLastOneIsShown() {
        var memory = MouseMemory()
        // A Mac that has run MouseHerdr before had an MX Master 4; a new one starts plain.
        XCTAssertEqual(MouseChooser.profile(for: nil, memory: memory, firstRun: false).id, "mxMaster4")
        XCTAssertEqual(MouseChooser.profile(for: nil, memory: memory, firstRun: true).id, "generic")
        memory.last = "msBasicOptical"
        XCTAssertEqual(MouseChooser.profile(for: nil, memory: memory, firstRun: true).id, "msBasicOptical")
        // A model picked while nothing was connected is kept until a mouse shows up.
        memory.chosen[MouseChooser.noDevice] = "razerViper"
        XCTAssertEqual(MouseChooser.profile(for: nil, memory: memory, firstRun: true).id, "razerViper")
        XCTAssertEqual(MouseChooser.profile(for: microsoft, memory: memory, firstRun: true).id, "msBasicOptical")
    }

    /// Mice coming and going over a morning, as the detector would report them.
    func testAMouseIsPickedUpAsItConnectsAndLetGoAsItLeaves() {
        var connected: [MouseDevice] = [trackpad]
        var arrivals = 0
        var memory = MouseMemory()
        func plugIn(_ device: MouseDevice) {
            arrivals += 1
            var d = device
            d.order = arrivals
            connected.append(d)
        }
        func unplug(_ device: MouseDevice) { connected.removeAll { $0.key == device.key } }
        func followed() -> (device: String?, profile: String) {
            let device = MouseChooser.active(among: MouseChooser.candidates(connected), pinned: memory.pinned)
            let profile = MouseChooser.profile(for: device, memory: memory, firstRun: true)
            if device != nil { memory.last = profile.id }
            return (device?.key, profile.id)
        }

        XCTAssertTrue(followed() == (nil, "generic"), "a new Mac with only its trackpad")
        plugIn(microsoft)
        XCTAssertTrue(followed() == (microsoft.key, "msBasicOptical"), "the Microsoft mouse is plugged in")
        plugIn(receiver)
        XCTAssertTrue(followed() == (microsoft.key, "msBasicOptical"), "a receiver does not take over from a mouse")
        plugIn(mx4)
        XCTAssertTrue(followed() == (mx4.key, "mxMaster4"), "the MX Master 4 connects and takes over")
        memory.pinned = microsoft.key
        XCTAssertTrue(followed() == (microsoft.key, "msBasicOptical"), "the Microsoft mouse is picked by hand")
        unplug(microsoft)
        XCTAssertTrue(followed() == (mx4.key, "mxMaster4"), "unplugged, the MX Master 4 is followed again")
        unplug(mx4)
        XCTAssertTrue(followed() == (receiver.key, "logitechReceiver"), "only the receiver is left")
        unplug(receiver)
        XCTAssertTrue(followed() == (nil, "logitechReceiver"), "with nothing connected the last one stays on show")
        plugIn(microsoft)
        XCTAssertTrue(followed() == (microsoft.key, "msBasicOptical"), "plugged back in, the choice made by hand holds again")
    }

    /// Before other mice were recognised, an MX Master 4 on its Bolt receiver was shown as one and
    /// its buttons worked. It must stay that way on a Mac that goes back that far.
    func testAnMXMaster4OnItsBoltReceiverIsStillTakenForOneWhereItAlwaysWas() {
        let bolt = MouseDevice(vendorID: 0x046D, productID: 0xC548, name: "USB Receiver", transport: "USB", buttons: 16)
        var memory = MouseMemory()
        // A Mac new to MouseHerdr: a receiver is a receiver.
        XCTAssertEqual(MouseChooser.profile(for: bolt, memory: memory, firstRun: true).id, "logitechReceiver")

        memory.boltCarriesMXMaster4 = true
        XCTAssertEqual(MouseChooser.profile(for: bolt, memory: memory, firstRun: false).id, "mxMaster4")
        // An MX Master 4 pairs with no other receiver, so the Unifying one is not taken for it.
        XCTAssertEqual(MouseChooser.profile(for: receiver, memory: memory, firstRun: false).id, "logitechReceiver")
        XCTAssertEqual(MouseChooser.profile(for: microsoft, memory: memory, firstRun: false).id, "msBasicOptical")
        // It still ranks as a receiver, so a real MX Master 4 on Bluetooth is followed ahead of it.
        XCTAssertEqual(MouseChooser.candidates([bolt, mx4]).first?.key, mx4.key)
        // And a model picked by hand still wins.
        memory.chosen[bolt.key] = "mxMaster3S"
        XCTAssertEqual(MouseChooser.profile(for: bolt, memory: memory, firstRun: false).id, "mxMaster3S")
    }

    // MARK: The direct link

    /// The controls an MX Master 4 lists over HID++, in the shape the app reads them:
    /// flags 0x20 can be captured, 0x80 is not a real button, flags2 0x01 reports movement.
    private let mx4Controls: [HIDPP.Control] = [
        HIDPP.Control(cid: 0x0050, tid: 0x0038, flags: 0x01, flags2: 0x00),     // left
        HIDPP.Control(cid: 0x0051, tid: 0x0039, flags: 0x01, flags2: 0x00),     // right
        HIDPP.Control(cid: 0x0052, tid: 0x003A, flags: 0x31, flags2: 0x00),     // middle
        HIDPP.Control(cid: 0x0053, tid: 0x003C, flags: 0x31, flags2: 0x00),     // back
        HIDPP.Control(cid: 0x0056, tid: 0x003E, flags: 0x31, flags2: 0x00),     // forward
        HIDPP.Control(cid: 0x00C3, tid: 0x00A9, flags: 0x31, flags2: 0x01),     // gesture button
        HIDPP.Control(cid: 0x00C4, tid: 0x009D, flags: 0x31, flags2: 0x00),     // top button
        HIDPP.Control(cid: 0x00D7, tid: 0x00B4, flags: 0xA0, flags2: 0x01),     // virtual gesture button
        HIDPP.Control(cid: 0x01A0, tid: 0x0140, flags: 0x31, flags2: 0x00),     // haptic panel
    ]

    func testTheMXMaster4CapturesTheControlsItAlwaysDid() {
        XCTAssertEqual(MouseProfile.mxMaster4.captures(among: mx4Controls),
                       [.gesture: 0x00C3, .modeShift: 0x00C4, .thumbPanel: 0x01A0])
        // A haptic panel under another id is taken as the one control nothing else accounts for.
        let renumbered = mx4Controls.filter { $0.cid != 0x01A0 } + [HIDPP.Control(cid: 0x01A7, tid: 0x0140, flags: 0x31, flags2: 0x00)]
        XCTAssertEqual(MouseProfile.mxMaster4.captures(among: renumbered)[.thumbPanel], 0x01A7)
        // A control the mouse lists but won't hand over is left alone.
        let locked = mx4Controls.map { $0.cid == 0x00C4 ? HIDPP.Control(cid: 0x00C4, tid: 0x009D, flags: 0x01, flags2: 0x00) : $0 }
        XCTAssertNil(MouseProfile.mxMaster4.captures(among: locked)[.modeShift])
        XCTAssertTrue(MouseProfile.mxMaster4.captures(among: []).isEmpty)
    }

    func testOtherProfilesCaptureOnlyWhatTheyNameAndTheMouseReports() {
        let threeS = MouseProfile.named("mxMaster3S")!
        XCTAssertEqual(threeS.captures(among: mx4Controls), [.back: 0x0053, .forward: 0x0056, .gesture: 0x00C3, .modeShift: 0x00C4])
        XCTAssertEqual(threeS.captures(among: mx4Controls.filter { $0.cid != 0x00C3 }), [.back: 0x0053, .forward: 0x0056, .modeShift: 0x00C4])
        // The wheel click stays an ordinary button.
        XCTAssertEqual(threeS.control(.middle)?.source, .button(2))
        // A mouse with only the usual buttons captures nothing over the link.
        XCTAssertTrue(MouseProfile.generic.captures(among: mx4Controls).isEmpty)
        XCTAssertTrue(MouseProfile.named("msBasicOptical")!.captures(among: mx4Controls).isEmpty)
    }

    /// A control left captured with nobody listening is a dead button.
    func testControlsAreHandedBackWhenTheirMouseIsNoLongerFollowed() {
        let mine: Set<UInt16> = [0x00C3, 0x00C4, 0x01A0]
        func handBack(captured: Set<UInt16>, wanted: Set<UInt16>, followed: Bool, arrived: Bool) -> Set<UInt16> {
            MouseChooser.handBack(captured: captured, wanted: wanted, followed: followed, arrived: arrived, reported: mx4Controls)
        }
        // Followed, as an MX Master 4 on its own always is: nothing goes back, connecting or not.
        XCTAssertEqual(handBack(captured: mine, wanted: mine, followed: true, arrived: true), [])
        XCTAssertEqual(handBack(captured: [], wanted: mine, followed: true, arrived: true), [])
        XCTAssertEqual(handBack(captured: mine, wanted: mine, followed: true, arrived: false), [])
        // Followed under a profile that wants less: the rest goes back.
        XCTAssertEqual(handBack(captured: mine, wanted: [0x00C3, 0x00C4], followed: true, arrived: false), [0x01A0])

        // Another mouse is picked while the link is up: all of it goes back.
        XCTAssertEqual(handBack(captured: mine, wanted: [], followed: false, arrived: false), mine)
        // The link dropped and came back while another mouse is followed. The mouse was told its
        // old captures again as it reconnected, so they go back, with anything else it could hold.
        let everything: Set<UInt16> = [0x0052, 0x0053, 0x0056, 0x00C3, 0x00C4, 0x01A0]
        XCTAssertEqual(handBack(captured: mine, wanted: [], followed: false, arrived: true), everything)
        // The app was killed with controls captured and starts again following another mouse.
        XCTAssertEqual(handBack(captured: [], wanted: [], followed: false, arrived: true), everything)
        // Once that is done there is nothing more to send.
        XCTAssertEqual(handBack(captured: [], wanted: [], followed: false, arrived: false), [])
    }

    // MARK: Reading the real thing

    /// The scan itself, against whatever this machine has. It opens no device, so it needs no
    /// permission and cannot fail on a build server with no mouse at all.
    func testScanningTheConnectedDevicesNeedsNothingAndDescribesThem() {
        let devices = MouseDetector.connected()
        for device in devices {
            XCTAssertFalse(device.key.isEmpty)
            XCTAssertGreaterThanOrEqual(device.vendorID, 0)
            XCTAssertGreaterThanOrEqual(device.buttons, 0)
        }
        let list = MouseChooser.candidates(devices)
        XCTAssertEqual(Set(list.map(\.key)).count, list.count, "each mouse is listed once")
        XCTAssertFalse(list.contains { $0.kind == .ignored })
        if let followed = MouseChooser.active(among: list, pinned: nil) {
            XCTAssertNotNil(MouseProfile.named(MouseChooser.profile(for: followed, memory: MouseMemory(), firstRun: true).id))
        }
    }
}
