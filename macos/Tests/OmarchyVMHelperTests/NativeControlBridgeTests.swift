import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native update control protocol")
struct NativeControlBridgeTests {
    private let bootABI = "arm64-qemu-direct-v1"
    private let transaction = String(repeating: "a", count: 64)

    @Test("parses the update and health bridge CLI contracts")
    func parsesBridgeInvocation() throws {
        let update = try #require(NativeControlBridgeInvocation(arguments: [
            "42", "/tmp/control.sock", "/tmp/private/.control-event", "update",
            transaction, bootABI, "1",
        ]))
        #expect(update.targetPID == 42)
        #expect(update.socketPath == "/tmp/control.sock")
        #expect(update.eventPath == "/tmp/private/.control-event")
        #expect(update.expectation == GuestControlExpectation(
            bootABI: bootABI,
            guestStateSchema: 1,
            kind: .update,
            transaction: transaction
        ))

        let health = try #require(NativeControlBridgeInvocation(arguments: [
            "42", "/tmp/control.sock", "/tmp/private/.control-event", "health",
            "-", bootABI, "1",
        ]))
        #expect(health.expectation.kind == .health)
        #expect(health.expectation.transaction == nil)
    }

    @Test("rejects malformed control bridge CLI arguments")
    func rejectsInvalidBridgeInvocation() {
        let invalid = [
            ["1", "/tmp/socket", "/tmp/private/.control-event", "health", "-", bootABI, "1"],
            ["42", "/tmp/socket", "/tmp/private/.control-event", "other", "-", bootABI, "1"],
            ["42", "/tmp/socket", "/tmp/private/.control-event", "update", "-", bootABI, "1"],
            ["42", "/tmp/socket", "/tmp/private/.control-event", "update", "short", bootABI, "1"],
            ["42", "/tmp/socket", "/tmp/private/.control-event", "health", "-", "bad/abi", "1"],
            ["42", "/tmp/socket", "/tmp/private/.control-event", "health", "-", bootABI, "0"],
        ]
        for arguments in invalid {
            #expect(NativeControlBridgeInvocation(arguments: arguments) == nil)
        }
    }

    @Test("accepts exact update completion and health messages")
    func acceptsMessages() throws {
        let update = try GuestControlMessage.decode(Data("""
        {"bootABI":"\(bootABI)","fromGuestStateSchema":0,"guestStateSchema":1,"protocolVersion":1,"status":"complete","transaction":"\(transaction)","type":"update"}
        """.utf8))
        #expect(update == GuestControlMessage(
            bootABI: bootABI,
            errorCode: nil,
            fromGuestStateSchema: 0,
            guestStateSchema: 1,
            kind: .update,
            protocolVersion: 1,
            readiness: nil,
            status: "complete",
            transaction: transaction
        ))
        #expect(GuestControlExpectation(
            bootABI: bootABI,
            guestStateSchema: 1,
            kind: .update,
            transaction: transaction
        ).accepts(update))

        let health = try GuestControlMessage.decode(Data("""
        {"bootABI":"\(bootABI)","guestStateSchema":1,"protocolVersion":1,"readiness":"system","status":"ready","transaction":"\(transaction)","type":"health"}
        """.utf8))
        #expect(health.kind == .health)
        #expect(health.readiness == .system)
        #expect(health.transaction == transaction)

        let graphicalHealth = try GuestControlMessage.decode(Data("""
        {"bootABI":"\(bootABI)","guestStateSchema":1,"protocolVersion":1,"readiness":"graphical","status":"ready","type":"health"}
        """.utf8))
        #expect(graphicalHealth.kind == .health)
        #expect(graphicalHealth.readiness == .graphical)
        #expect(graphicalHealth.transaction == nil)

        var sequence = GuestControlSequence(expectation: GuestControlExpectation(
            bootABI: bootABI,
            guestStateSchema: 1,
            kind: .update,
            transaction: transaction
        ))
        #expect(try !sequence.receive(update))
        #expect(try sequence.receive(health))

        let failed = try GuestControlMessage.decode(Data("""
        {"bootABI":"\(bootABI)","errorCode":"package-transaction-failed","fromGuestStateSchema":0,"guestStateSchema":1,"protocolVersion":1,"status":"failed","transaction":"\(transaction)","type":"update"}
        """.utf8))
        #expect(failed.errorCode == "package-transaction-failed")
        var failedSequence = GuestControlSequence(expectation: GuestControlExpectation(
            bootABI: bootABI,
            guestStateSchema: 1,
            kind: .update,
            transaction: transaction
        ))
        #expect(throws: HelperError.io("guest update failed: package-transaction-failed")) {
            try failedSequence.receive(failed)
        }

        let resumed = try GuestControlMessage.decode(Data("""
        {"bootABI":"\(bootABI)","fromGuestStateSchema":1,"guestStateSchema":1,"protocolVersion":1,"status":"complete","transaction":"\(transaction)","type":"update"}
        """.utf8))
        var resumedSequence = GuestControlSequence(expectation: GuestControlExpectation(
            bootABI: bootABI,
            guestStateSchema: 1,
            kind: .update,
            transaction: transaction
        ))
        #expect(try !resumedSequence.receive(resumed))
        #expect(try resumedSequence.receive(health))
    }

    @Test("rejects stale, fractional, noncanonical, and oversized messages")
    func rejectsInvalidMessages() throws {
        let invalid = [
            "{\"bootABI\":\"\(bootABI)\",\"fromGuestStateSchema\":0,\"guestStateSchema\":1,\"protocolVersion\":1,\"status\":\"complete\",\"transaction\":\"short\",\"type\":\"update\"}",
            "{\"bootABI\":\"\(bootABI)\",\"guestStateSchema\":1.5,\"protocolVersion\":1,\"status\":\"ready\",\"type\":\"health\"}",
            "{\"bootABI\":\"bad/abi\",\"guestStateSchema\":1,\"protocolVersion\":1,\"status\":\"ready\",\"type\":\"health\"}",
            "{\"bootABI\":\"\(bootABI)\",\"extra\":true,\"guestStateSchema\":1,\"protocolVersion\":1,\"status\":\"ready\",\"type\":\"health\"}",
            "{\"bootABI\":\"\(bootABI)\",\"guestStateSchema\":1,\"protocolVersion\":1,\"readiness\":\"system\",\"status\":\"ready\",\"type\":\"health\"}",
            "{\"bootABI\":\"\(bootABI)\",\"guestStateSchema\":1,\"protocolVersion\":1,\"readiness\":\"graphical\",\"status\":\"ready\",\"transaction\":\"\(transaction)\",\"type\":\"health\"}",
            "{\"bootABI\":\"\(bootABI)\",\"errorCode\":\"Bad_Error\",\"fromGuestStateSchema\":0,\"guestStateSchema\":1,\"protocolVersion\":1,\"status\":\"failed\",\"transaction\":\"\(transaction)\",\"type\":\"update\"}",
        ]
        for message in invalid {
            #expect(throws: HelperError.self) {
                try GuestControlMessage.decode(Data(message.utf8))
            }
        }
        #expect(throws: HelperError.self) {
            try GuestControlMessage.decode(Data(repeating: 0x61, count: 4_097))
        }

        let valid = try GuestControlMessage.decode(Data("""
        {"bootABI":"\(bootABI)","fromGuestStateSchema":0,"guestStateSchema":1,"protocolVersion":1,"status":"complete","transaction":"\(transaction)","type":"update"}
        """.utf8))
        #expect(!GuestControlExpectation(
            bootABI: bootABI,
            guestStateSchema: 1,
            kind: .update,
            transaction: String(repeating: "b", count: 64)
        ).accepts(valid))
    }
}
