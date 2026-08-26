import Darwin
import Foundation

struct NativeControlBridgeInvocation: Equatable {
    let targetPID: pid_t
    let socketPath: String
    let eventPath: String
    let expectation: GuestControlExpectation

    /// Parses the seven arguments following `--bridge-native-control`.
    init?(arguments: [String]) {
        guard arguments.count == 7,
              let targetPID = pid_t(arguments[0]), targetPID > 1,
              let kind = GuestControlMessage.Kind(rawValue: arguments[3]),
              let guestStateSchema = Int(arguments[6]), guestStateSchema > 0,
              Self.isSafeBootABI(arguments[5]) else { return nil }

        let transaction: String?
        if arguments[4] == "-" {
            transaction = nil
        } else {
            guard Self.isIdentity(arguments[4]) else { return nil }
            transaction = arguments[4]
        }
        guard kind != .update || transaction != nil else { return nil }

        self.targetPID = targetPID
        socketPath = arguments[1]
        eventPath = arguments[2]
        expectation = GuestControlExpectation(
            bootABI: arguments[5],
            guestStateSchema: guestStateSchema,
            kind: kind,
            transaction: transaction
        )
    }

    private static func isSafeBootABI(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
