import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native clipboard bridge")
struct NativeClipboardBridgeTests {
    @Test("clipboard messages round-trip through the newline-delimited JSON schema")
    func roundTrip() throws {
        let message = try #require(ClipboardMessage(format: .text, payload: Data("héllo\n".utf8)))
        let encoded = try message.encode()
        #expect(encoded.last == 0x0A)
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"data":"aMOpbGxvCg==","format":"text/plain;charset=utf-8","type":"clipboard"}"# + "\n"
        )
        #expect(try ClipboardMessage.decode(encoded.dropLast()) == .clipboard(message))
        #expect(try ClipboardMessage.decode(Data(#"{"type":"sync"}"#.utf8)) == .sync)
    }

    @Test("unknown formats are ignored while malformed lines are rejected")
    func decodeValidation() throws {
        #expect(
            try ClipboardMessage.decode(
                Data(#"{"data":"AAAA","format":"text/html","type":"clipboard"}"#.utf8)
            ) == .ignored
        )
        #expect(
            try ClipboardMessage.decode(
                Data(#"{"data":"","format":"image/png","type":"clipboard"}"#.utf8)
            ) == .ignored
        )
        for line in [
            "not json",
            #"{"type":"clipboard"}"#,
            #"{"type":"sync","extra":1}"#,
            #"{"data":"%%%","format":"image/png","type":"clipboard"}"#,
            #"{"data":"AAAA","format":"image/png","type":"clipboard","more":true}"#,
            #"{"type":"select"}"#,
        ] {
            #expect(throws: HelperError.self) {
                try ClipboardMessage.decode(Data(line.utf8))
            }
        }
        #expect(ClipboardMessage(format: .text, payload: Data([0xFF, 0xFE])) == nil)
        #expect(ClipboardMessage(format: .png, payload: Data()) == nil)
    }

    @Test("echoes are suppressed in both directions and new content still flows")
    func echoSuppression() throws {
        var state = ClipboardSyncState()
        func host(_ message: ClipboardMessage) -> Bool { state.hostChanged(message) }
        func guest(_ message: ClipboardMessage) -> Bool { state.guestChanged(message) }
        let fromMac = try #require(ClipboardMessage(format: .text, payload: Data("from mac".utf8)))
        let fromGuest = try #require(ClipboardMessage(format: .text, payload: Data("from guest".utf8)))
        let image = try #require(ClipboardMessage(format: .png, payload: Data([0x89, 0x50, 0x4E, 0x47])))

        #expect(host(fromMac))
        // wl-copy in the guest re-announces the same selection; do not bounce it back.
        #expect(!guest(fromMac))

        #expect(guest(fromGuest))
        // Writing the pasteboard bumps its change count; the poller must not re-send.
        #expect(!host(fromGuest))

        #expect(host(image))
        #expect(!guest(image))
        // Copying earlier guest content again is a real change once the host moved on.
        #expect(guest(fromGuest))
        #expect(host(fromMac))
        #expect(!guest(fromMac))
    }

    @Test("echo markers expire so a genuine repeat of guest content is not lost")
    func echoMarkersExpire() throws {
        var state = ClipboardSyncState()
        func host(_ message: ClipboardMessage, at time: TimeInterval) -> Bool { state.hostChanged(message, at: time) }
        func guest(_ message: ClipboardMessage, at time: TimeInterval) -> Bool { state.guestChanged(message, at: time) }
        let a = try #require(ClipboardMessage(format: .text, payload: Data("A".utf8)))
        let b = try #require(ClipboardMessage(format: .text, payload: Data("B".utf8)))
        let window = ClipboardSyncState.echoWindow

        // Guest copies B, the Mac copies A, then the Mac copies B again well
        // after the guest's write. The final B is new content, not an echo.
        #expect(guest(b, at: 0))
        #expect(host(a, at: window + 1))
        #expect(host(b, at: window + 2))

        // Inside the window the mirrored write is still recognized as an echo.
        #expect(!guest(b, at: window + 2.1))
        #expect(guest(b, at: window * 2 + 3))
    }
}
