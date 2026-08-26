import CoreAudio
import Darwin
import Foundation

struct NativeAudioRouteRequest: Equatable {
    let direction: HostAudioDirection
    let deviceUID: String?

    static func decode(_ data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted() == ["deviceUID", "direction", "type"],
              object["type"] as? String == "select",
              let rawDirection = object["direction"] as? String,
              let direction = HostAudioDirection(rawValue: rawDirection) else {
            return nil
        }
        let rawUID = object["deviceUID"]
        if rawUID is NSNull {
            return Self(direction: direction, deviceUID: nil)
        }
        guard let deviceUID = rawUID as? String, !deviceUID.isEmpty else { return nil }
        return Self(direction: direction, deviceUID: deviceUID)
    }
}

struct NativeAudioCatalogMessage {
    static func encode(
        catalog: HostAudioDeviceCatalog,
        preferences: AudioRoutingPreferences
    ) throws -> Data {
        func records(_ devices: [HostAudioDevice]) -> [[String: String]] {
            devices.map { ["deviceUID": $0.uid, "name": $0.sdlName] }
        }

        let object: [String: Any] = [
            "type": "catalog",
            "outputs": records(catalog.outputDevices),
            "inputs": records(catalog.inputDevices),
            "selectedOutputUID": preferences.output.deviceUID as Any? ?? NSNull(),
            "selectedInputUID": preferences.input.deviceUID as Any? ?? NSNull(),
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

/// Atomically publishes the selected SDL endpoint to the patched QEMU audio
/// backend. `default` is deliberately not valid canonical base64, so arbitrary
/// CoreAudio names cannot collide with the sentinel.
struct NativeAudioRouteFileStore {
    private let directory: URL

    init(directoryPath: String) throws {
        guard directoryPath.hasPrefix("/"), !directoryPath.utf8.contains(0) else {
            throw HelperError.io("audio route directory must be an absolute pathname")
        }
        let url = URL(fileURLWithPath: directoryPath).standardizedFileURL
        guard url.path == directoryPath else {
            throw HelperError.io("audio route directory must already be standardized")
        }
        var information = stat()
        guard lstat(directoryPath, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == getuid(),
              (information.st_mode & 0o077) == 0 else {
            throw HelperError.io("audio route directory must be private and owned by this user")
        }
        directory = url
    }

    func publish(_ sdlName: String?, for direction: HostAudioDirection) throws {
        let payload = sdlName.map { Data($0.utf8).base64EncodedString() } ?? "default"
        let destination = directory.appendingPathComponent(direction.rawValue, isDirectory: false)
        let temporary = directory.appendingPathComponent(
            ".\(direction.rawValue).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw HelperError.io("cannot create the audio route update")
        }
        do {
            let bytes = Array((payload + "\n").utf8)
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        throw HelperError.io("cannot write the audio route update")
                    }
                }
            }
            guard fsync(descriptor) == 0 else {
                throw HelperError.io("cannot flush the audio route update")
            }
        } catch {
            Darwin.close(descriptor)
            unlink(temporary.path)
            throw error
        }
        Darwin.close(descriptor)
        guard rename(temporary.path, destination.path) == 0 else {
            unlink(temporary.path)
            throw HelperError.io("cannot publish the audio route update")
        }
    }
}

final class CoreAudioDeviceChangeMonitor {
    private let queue = DispatchQueue(label: "dev.tryomarchy.native.audio-devices")
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(onChange: @escaping () -> Void) throws {
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
            guard status == noErr else {
                removeListeners()
                throw HelperError.io("cannot monitor CoreAudio device changes (status \(status))")
            }
            listeners.append((address, listener))
        }
    }

    deinit {
        removeListeners()
    }

    private func removeListeners() {
        for (storedAddress, listener) in listeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
        }
        listeners.removeAll()
    }
}

final class NativeAudioBridge {
    private let descriptor: Int32
    private let deviceProvider: HostAudioDeviceProviding
    private let preferenceStore: AudioRoutingPreferenceStore
    private let routeStore: NativeAudioRouteFileStore
    private let stateQueue = DispatchQueue(label: "dev.tryomarchy.native.audio-bridge-state")
    private let writeQueue = DispatchQueue(label: "dev.tryomarchy.native.audio-bridge-writes")
    private let stopLock = NSLock()
    private var monitor: CoreAudioDeviceChangeMonitor?
    private var stopped = false

    init(
        targetPID: pid_t,
        socketPath: String,
        routeDirectoryPath: String,
        deviceProvider: HostAudioDeviceProviding = CoreAudioHostAudioDeviceProvider(),
        preferenceStore: AudioRoutingPreferenceStore = AudioRoutingPreferenceStore()
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native audio bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "audio bridge")
        self.deviceProvider = deviceProvider
        self.preferenceStore = preferenceStore
        routeStore = try NativeAudioRouteFileStore(directoryPath: routeDirectoryPath)
        monitor = try CoreAudioDeviceChangeMonitor { [weak self] in
            self?.catalogDidChange()
        }
    }

    deinit {
        stop()
    }

    func run() throws {
        try publishEffectiveRoutesAndCatalog()
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    try handle(line)
                    line.removeAll(keepingCapacity: true)
                } else if byte != 0x0D {
                    guard line.count < 65_536 else {
                        throw HelperError.io("guest audio request exceeds 64 KiB")
                    }
                    line.append(byte)
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest audio channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        monitor = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func handle(_ data: Data) throws {
        try stateQueue.sync {
            try handleSerialized(data)
        }
    }

    private func handleSerialized(_ data: Data) throws {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object.keys.sorted() == ["type"],
           object["type"] as? String == "get-catalog" {
            try sendCatalog()
            return
        }
        guard let request = NativeAudioRouteRequest.decode(data) else {
            throw HelperError.io("guest sent an invalid audio request")
        }

        let catalog = deviceProvider.catalog()
        let selection: AudioRouteSelection
        if let uid = request.deviceUID {
            guard let device = catalog.device(uid: uid, direction: request.direction) else {
                try sendCatalog(catalog: catalog)
                return
            }
            selection = .device(uid: uid, lastKnownName: device.sdlName)
        } else {
            selection = .systemDefault
        }
        preferenceStore.set(selection, for: request.direction)
        try publishEffectiveRoutes(catalog: catalog)
        try sendCatalog(catalog: catalog)
    }

    private func catalogDidChange() {
        stateQueue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
                try self.publishEffectiveRoutesAndCatalog()
            } catch {
                fputs("[audio-bridge] \(error.localizedDescription)\n", stderr)
                self.stop()
            }
        }
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func publishEffectiveRoutesAndCatalog() throws {
        let catalog = deviceProvider.catalog()
        try publishEffectiveRoutes(catalog: catalog)
        try sendCatalog(catalog: catalog)
    }

    private func publishEffectiveRoutes(catalog: HostAudioDeviceCatalog) throws {
        let configuration = AudioLaunchConfiguration.make(
            baseEnvironment: [:],
            preferences: preferenceStore.load(),
            catalog: catalog
        )
        try routeStore.publish(configuration.routes.outputSDLName, for: .output)
        try routeStore.publish(configuration.routes.inputSDLName, for: .input)
    }

    private func sendCatalog(catalog: HostAudioDeviceCatalog? = nil) throws {
        let data = try NativeAudioCatalogMessage.encode(
            catalog: catalog ?? deviceProvider.catalog(),
            preferences: preferenceStore.load()
        )
        try writeQueue.sync {
            try NativeBridgeSocket.writeAll(data, to: descriptor, label: "audio")
        }
    }
}
