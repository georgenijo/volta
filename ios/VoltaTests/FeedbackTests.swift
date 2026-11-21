import XCTest
@testable import Volta

final class FeedbackTests: XCTestCase {
    func testCommandPulseBuzzesOncePerStage() {
        let a = UUID(), b = UUID()
        let none = CommandPulse(id: nil, outcome: nil)
        let sending = CommandPulse(id: a, outcome: .sending)
        let accepted = CommandPulse(id: a, outcome: .accepted)
        let confirmed = CommandPulse(id: a, outcome: .confirmed)
        XCTAssertNil(CommandPulse.feedback(from: none, to: none))
        XCTAssertEqual(CommandPulse.feedback(from: none, to: sending), .commandSent)
        XCTAssertEqual(CommandPulse.feedback(from: sending, to: accepted), .commandConfirmed)
        XCTAssertNil(CommandPulse.feedback(from: accepted, to: confirmed), "accepted then confirmed buzzes once")
        XCTAssertEqual(CommandPulse.feedback(from: sending, to: confirmed), .commandConfirmed)
        XCTAssertEqual(CommandPulse.feedback(from: sending, to: CommandPulse(id: a, outcome: .failed)), .commandFailed)
        XCTAssertNil(CommandPulse.feedback(from: sending, to: CommandPulse(id: a, outcome: .unknown)))
        XCTAssertEqual(CommandPulse.feedback(from: confirmed, to: CommandPulse(id: b, outcome: .sending)), .commandSent,
                       "a new command starts its own pulse")
    }
}
