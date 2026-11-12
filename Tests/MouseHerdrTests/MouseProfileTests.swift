import XCTest
@testable import MouseHerdr

final class MouseProfileTests: XCTestCase {
    func testMXMaster4IsRecognizedByProductIDOrName() {
        XCTAssertEqual(MouseProfile.matching(productID: 0xB042, name: "Unknown").id, "mxMaster4")
        XCTAssertEqual(MouseProfile.matching(productID: 0, name: "Logitech mx master 4").id, "mxMaster4")
    }

    func testUnknownMouseUsesOnlyGenericControls() {
        let profile = MouseProfile.matching(productID: 0, name: "Unrecognized mouse")
        XCTAssertEqual(profile.id, "generic")
        XCTAssertFalse(profile.hasHaptics)
        XCTAssertEqual(Set(profile.controls.map(\.slot)), [.middle, .back, .forward])
        XCTAssertTrue(profile.controls.allSatisfy { $0.cid == nil && !$0.gestures })
    }

    func testProfilesHaveUnambiguousControlsAndUsableDefaults() {
        for profile in MouseProfile.all + [.generic] {
            let slots = profile.controls.map(\.slot)
            XCTAssertEqual(Set(slots).count, slots.count, profile.id)
            XCTAssertNotNil(profile.control(profile.firstSelected), profile.id)
            XCTAssertLessThanOrEqual(profile.controls.filter(\.gestures).count, 1, profile.id)
            for slot in slots {
                XCTAssertNotNil(profile.defaults[slot], "\(profile.id): \(slot)")
            }
            for action in profile.defaults.values {
                XCTAssertNotNil(Catalog.byID[action.kind], "\(profile.id): \(action.kind)")
            }
            let buttons = profile.controls.compactMap(\.button)
            let cids = profile.controls.compactMap(\.cid)
            XCTAssertEqual(Set(buttons).count, buttons.count, profile.id)
            XCTAssertEqual(Set(cids).count, cids.count, profile.id)
        }
    }
}
