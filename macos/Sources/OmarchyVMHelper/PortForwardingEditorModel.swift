import Foundation

struct PortForwardingDraft: Equatable {
    var hostPort: String
    var guestPort: String
    var `protocol`: PortForwardProtocol

    init(mapping: PortForwardMapping) {
        hostPort = String(mapping.hostPort)
        guestPort = String(mapping.guestPort)
        `protocol` = mapping.protocol
    }

    init(
        hostPort: String = "",
        guestPort: String = "",
        protocol protocolValue: PortForwardProtocol = .tcp
    ) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.protocol = protocolValue
    }
}

struct PortForwardingEditorValidation: Equatable {
    let mappings: [PortForwardMapping]?
    let message: String
    let isError: Bool
    let hasChanges: Bool

    var canSave: Bool {
        mappings != nil && hasChanges
    }
}

/// Deterministic edit and validation state for the AppKit port-forwarding
/// sheet. The window only renders this model and forwards user intent to it.
struct PortForwardingEditorModel {
    private let initialMappings: [PortForwardMapping]
    private(set) var drafts: [PortForwardingDraft]

    init(mappings: [PortForwardMapping]) {
        initialMappings = mappings
        drafts = mappings.map(PortForwardingDraft.init(mapping:))
    }

    var canAddMapping: Bool {
        drafts.count < PortForwardPolicy.maximumMappings
    }

    @discardableResult
    mutating func addEmptyMapping() -> Int? {
        add(PortForwardingDraft())
    }

    @discardableResult
    mutating func addSSHPreset() -> Int? {
        add(PortForwardingDraft(mapping: PortForwardPreset.ssh))
    }

    mutating func removeMapping(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
    }

    mutating func updateHostPort(_ value: String, at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts[index].hostPort = value
    }

    mutating func updateGuestPort(_ value: String, at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts[index].guestPort = value
    }

    mutating func updateProtocol(_ value: PortForwardProtocol, at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts[index].protocol = value
    }

    var validation: PortForwardingEditorValidation {
        guard !drafts.isEmpty else {
            return result(mappings: [], message: "", isError: false)
        }

        var mappings: [PortForwardMapping] = []
        for (offset, draft) in drafts.enumerated() {
            let row = offset + 1
            let host = draft.hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
            let guest = draft.guestPort.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !guest.isEmpty else {
                return result(mappings: nil, message: "", isError: false)
            }
            guard host.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let hostPort = Int(host),
                  PortForwardPolicy.validPortRange.contains(hostPort) else {
                return result(
                    mappings: nil,
                    message: "Mac port in mapping \(row) must be a number from 1 to 65535.",
                    isError: true
                )
            }
            guard guest.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let guestPort = Int(guest),
                  PortForwardPolicy.validPortRange.contains(guestPort) else {
                return result(
                    mappings: nil,
                    message: "Omarchy port in mapping \(row) must be a number from 1 to 65535.",
                    isError: true
                )
            }
            mappings.append(
                PortForwardMapping(
                    hostPort: hostPort,
                    guestPort: guestPort,
                    protocol: draft.protocol
                )
            )
        }

        do {
            try PortForwardPolicy.validate(mappings)
        } catch {
            return result(
                mappings: nil,
                message: error.localizedDescription,
                isError: true
            )
        }

        return result(mappings: mappings, message: "", isError: false)
    }

    private mutating func add(_ draft: PortForwardingDraft) -> Int? {
        guard canAddMapping else { return nil }
        drafts.append(draft)
        return drafts.index(before: drafts.endIndex)
    }

    private func result(
        mappings: [PortForwardMapping]?,
        message: String,
        isError: Bool
    ) -> PortForwardingEditorValidation {
        PortForwardingEditorValidation(
            mappings: mappings,
            message: message,
            isError: isError,
            hasChanges: mappings.map { $0 != initialMappings } ?? false
        )
    }
}
