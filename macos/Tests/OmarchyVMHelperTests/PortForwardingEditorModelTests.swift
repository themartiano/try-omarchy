import Testing
@testable import OmarchyVMHelper

@Suite("Port forwarding editor model")
struct PortForwardingEditorModelTests {
    @Test("SSH preset is inserted as an ordinary editable mapping")
    func addsEditableSSHPreset() {
        var model = PortForwardingEditorModel(mappings: [])

        #expect(model.addSSHPreset() == 0)
        #expect(model.drafts == [
            PortForwardingDraft(hostPort: "2222", guestPort: "22", protocol: .tcp),
        ])

        model.updateHostPort("2223", at: 0)
        #expect(model.validation.mappings == [
            PortForwardMapping(hostPort: 2223, guestPort: 22, protocol: .tcp),
        ])
        #expect(model.validation.canSave)
    }

    @Test("ordered TCP and UDP edits produce the exact saved mapping list")
    func preservesOrderAndProtocol() {
        var model = PortForwardingEditorModel(mappings: [])
        model.addEmptyMapping()
        model.updateHostPort("8080", at: 0)
        model.updateGuestPort("3000", at: 0)
        model.addEmptyMapping()
        model.updateHostPort("5353", at: 1)
        model.updateGuestPort("5353", at: 1)
        model.updateProtocol(.udp, at: 1)

        #expect(model.validation.mappings == [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ])
        #expect(model.validation.canSave)
    }

    @Test("removing a mapping preserves the surrounding order")
    func removesOneMapping() {
        let initial = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ]
        var model = PortForwardingEditorModel(mappings: initial)

        model.removeMapping(at: 1)

        #expect(model.validation.mappings == [initial[0], initial[2]])
        #expect(model.validation.canSave)
    }

    @Test("incomplete input waits while invalid input reports the exact row")
    func distinguishesIncompleteAndInvalidInput() {
        var model = PortForwardingEditorModel(mappings: [])
        model.addEmptyMapping()

        #expect(model.validation.mappings == nil)
        #expect(model.validation.message.isEmpty)
        #expect(!model.validation.isError)
        #expect(!model.validation.canSave)

        model.updateHostPort("8080", at: 0)
        model.updateGuestPort("3000", at: 0)
        model.addEmptyMapping()
        model.updateHostPort("70000", at: 1)
        model.updateGuestPort("4000", at: 1)

        #expect(model.validation.mappings == nil)
        #expect(model.validation.message ==
            "Mac port in mapping 2 must be a number from 1 to 65535.")
        #expect(model.validation.isError)
        #expect(!model.validation.canSave)
    }

    @Test("only ASCII decimal ports are accepted and surrounding whitespace is ignored")
    func parsesPortsStrictly() {
        var model = PortForwardingEditorModel(mappings: [])
        model.addEmptyMapping()
        model.updateHostPort(" 8080\n", at: 0)
        model.updateGuestPort("\t3000 ", at: 0)
        #expect(model.validation.mappings == [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
        ])

        model.updateHostPort("٨٠٨٠", at: 0)
        #expect(model.validation.mappings == nil)
        #expect(model.validation.isError)
    }

    @Test("duplicate host ports are scoped to their transport protocol")
    func duplicateSemantics() {
        var model = PortForwardingEditorModel(mappings: [
            PortForwardMapping(hostPort: 2222, guestPort: 5353, protocol: .tcp),
        ])
        model.addSSHPreset()
        #expect(model.validation.message == "Mac TCP port 2222 is already mapped.")
        #expect(!model.validation.canSave)

        model.updateProtocol(.udp, at: 0)
        #expect(model.validation.message.isEmpty)
        #expect(model.validation.canSave)
    }

    @Test("unchanged content cannot be saved and the mapping limit cannot be exceeded")
    func changeAndLimitRules() {
        let maximum = (0..<PortForwardPolicy.maximumMappings).map {
            PortForwardMapping(hostPort: 10_000 + $0, guestPort: 20_000 + $0, protocol: .tcp)
        }
        var unchanged = PortForwardingEditorModel(mappings: maximum)
        #expect(!unchanged.validation.canSave)
        #expect(!unchanged.canAddMapping)
        #expect(unchanged.addEmptyMapping() == nil)
        #expect(unchanged.addSSHPreset() == nil)
        #expect(unchanged.drafts.count == PortForwardPolicy.maximumMappings)

        var empty = PortForwardingEditorModel(mappings: [])
        #expect(empty.validation.mappings == [])
        #expect(!empty.validation.canSave)
        empty.addEmptyMapping()
        empty.removeMapping(at: 0)
        #expect(!empty.validation.canSave)
    }
}
