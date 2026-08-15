#if canImport(AppKit)
import XCTest
import AppKit
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/HotKeyMonitor.swift doc
// comment -- "The default chord is Cmd+Shift+Backspace (keyCode 51)" and
// `matches(event:chord:)`'s doc comment: "Returns true if event matches
// chord under the same rules the live monitor uses" (reject any extra
// modifier beyond the configured chord).
final class HotKeyMonitorTests: DoctrineTestCase {

    private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - Chord

    func testDefaultChordIsCmdShiftBackspace() {
        let chord = HotKeyMonitor.Chord.defaultChord
        XCTAssertEqual(chord.keyCode, 51)
        XCTAssertTrue(chord.command)
        XCTAssertTrue(chord.shift)
    }

    func testChordDisplayStringUsesMacOSGlyphs() {
        XCTAssertEqual(HotKeyMonitor.Chord.defaultChord.displayString, "\u{2318}\u{21e7}\u{232b}")
    }

    // MARK: - matches(event:chord:)

    func testMatchesExactChord() {
        let event = keyEvent(keyCode: 51, modifiers: [.command, .shift])
        XCTAssertTrue(HotKeyMonitor.matches(event: event, chord: .defaultChord))
    }

    func testDoesNotMatchWrongKeyCode() {
        let event = keyEvent(keyCode: 12, modifiers: [.command, .shift])
        XCTAssertFalse(HotKeyMonitor.matches(event: event, chord: .defaultChord))
    }

    func testDoesNotMatchMissingShift() {
        let event = keyEvent(keyCode: 51, modifiers: [.command])
        XCTAssertFalse(HotKeyMonitor.matches(event: event, chord: .defaultChord))
    }

    func testDoesNotMatchMissingCommand() {
        let event = keyEvent(keyCode: 51, modifiers: [.shift])
        XCTAssertFalse(HotKeyMonitor.matches(event: event, chord: .defaultChord))
    }

    func testRejectsExtraOptionModifierEvenIfBaseChordMatches() {
        // Doc comment: "Reject any extra modifiers the user did not
        // configure, so the chord stays specific."
        let event = keyEvent(keyCode: 51, modifiers: [.command, .shift, .option])
        XCTAssertFalse(HotKeyMonitor.matches(event: event, chord: .defaultChord))
    }

    func testRejectsExtraControlModifierEvenIfBaseChordMatches() {
        let event = keyEvent(keyCode: 51, modifiers: [.command, .shift, .control])
        XCTAssertFalse(HotKeyMonitor.matches(event: event, chord: .defaultChord))
    }

    func testMatchesACustomChordExactly() {
        let custom = HotKeyMonitor.Chord(keyCode: 12, command: true, shift: false)
        let event = keyEvent(keyCode: 12, modifiers: [.command])
        XCTAssertTrue(HotKeyMonitor.matches(event: event, chord: custom))
    }

    func testChordEquality() {
        XCTAssertEqual(
            HotKeyMonitor.Chord(keyCode: 51, command: true, shift: true),
            HotKeyMonitor.Chord(keyCode: 51, command: true, shift: true)
        )
        XCTAssertNotEqual(
            HotKeyMonitor.Chord(keyCode: 51, command: true, shift: true),
            HotKeyMonitor.Chord(keyCode: 12, command: true, shift: true)
        )
    }
}
#endif
