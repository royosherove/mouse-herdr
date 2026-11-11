import SwiftUI

/// One thing on a mouse that can be given an action.
struct MouseControl: Identifiable {
    /// Where its presses come from.
    enum Source: Equatable {
        /// An ordinary button macOS reports by number (2 is the wheel click, 3 back, 4 forward), caught by the event tap.
        /// With `cid` set, the mouse can also report it over HID++, which is used instead when the direct link is up.
        case button(Int, cid: UInt16? = nil)
        /// A control macOS never sees. It only works once it is diverted over HID++.
        case hidpp(cid: UInt16)
        /// The sideways scroll wheel. Use it with the `.thumbWheel` slot, which has its own list of actions.
        case thumbWheel
    }

    /// How it is drawn on the picture.
    enum Shape {
        case button             // small capsule
        case wheel              // ridged capsule
        case pad(tilt: Double)  // large rounded panel, turned by `tilt` degrees
    }

    /// The key its action is saved under. Slots are shared between mice so settings carry over.
    let slot: Slot
    let title: String
    let blurb: String
    let source: Source
    /// Hold it and move the mouse for four more actions (the `.gestureUp` … `.gestureRight` slots).
    /// Those four slots are shared, so give this to at most one control per mouse.
    var gestures = false
    /// Through the event tap it only sends a short pulse, so it can be held only over HID++.
    var pulsesOverTap = false
    /// If the mouse doesn't report this control's `cid`, take the first capturable control nothing else accounts for.
    var orAnyUnlistedControl = false

    // Artwork, in the profile's canvas coordinates.
    let rect: CGRect
    var shape: Shape = .button
    /// Centre of its label, and whether the label sits left of the mouse.
    let chip: CGPoint
    let chipOnLeft: Bool

    var id: String { slot.rawValue }

    var button: Int? {
        if case .button(let n, _) = source { return n }
        return nil
    }

    var cid: UInt16? {
        switch source {
        case .button(_, let cid): return cid
        case .hidpp(let cid): return cid
        case .thumbWheel: return nil
        }
    }
}

/// The picture of a mouse, nose pointing up.
struct MouseArt {
    let size: CGSize
    let body: Path
    /// An optional second shape drawn behind the body, such as a thumb rest.
    var wing: Path? = nil
    /// Lines on the body: the split between the main buttons, the palm seam.
    let seams: Path
    /// The oval of the soft shadow under the mouse.
    let shadow: CGRect

    static let chipSize = CGSize(width: 172, height: 52)
}

/// Everything the app needs to know about one mouse model. To support another mouse, write one of
/// these (see Profiles/MXMaster4.swift) and add it to `all`.
struct MouseProfile: Identifiable {
    let id: String
    let name: String

    // How to recognise it: either is enough.
    var productIDs: Set<Int> = []       // HID product ids
    var nameContains: [String] = []     // parts of the name the mouse reports over HID++

    /// In the order they are drawn.
    let controls: [MouseControl]
    /// The control selected when the window first opens.
    let firstSelected: Slot
    let hasHaptics: Bool
    let defaults: [Slot: Action]
    /// Shown next to the Input Monitoring permission: what the direct link adds for this mouse.
    let directLinkWhy: String
    let art: MouseArt

    func control(_ slot: Slot) -> MouseControl? { controls.first { $0.slot == slot } }

    func matches(productID: Int, name: String) -> Bool {
        productIDs.contains(productID) || nameContains.contains { name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: Registry

    /// The mice we know. The first one that matches the connected device wins.
    static let all: [MouseProfile] = [.mxMaster4]

    /// Assumed until a device is identified, so the picture doesn't change under an MX Master 4 owner at every start.
    static let initial = mxMaster4

    static func matching(productID: Int, name: String) -> MouseProfile {
        all.first { $0.matches(productID: productID, name: name) } ?? .generic
    }

    static func named(_ id: String) -> MouseProfile? { (all + [.generic]).first { $0.id == id } }
}
