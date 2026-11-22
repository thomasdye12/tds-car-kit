import Foundation
import Network
import AVFoundation

/// All listener/session state is confined to queue. UI callbacks are always main-thread.
final class NativeReceiver {
    private let queue = DispatchQueue(label: "TDSCarKit.receiver")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [UUID: SessionState] = [:]
    private let videoSlots = DispatchSemaphore(value: 3)
    private var generation = UUID()
    private var airPlayIdentity: AirPlayCredentials?
    // NetService must be published/stopped on a thread with a run loop (main).
    private var discoveryService: NetService?
    var onLog: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onControlConnected: (() -> Void)?
    var onVideo: ((Data) -> Void)?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    var onFailure: (() -> Void)?

    func start(configuration: ReceiverConfiguration, identity: AccessoryIdentity, advertise: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            do { self.airPlayIdentity = advertise ? try AirPlayCredentials() : nil }
            catch { self.fail("AirPlay identity failed: \(error.localizedDescription)"); return }
            if configuration.audioEnabled {
                do {
                    for bits: UInt64 in [0x10000000, 0x20000000, 0x40000000] {
                        let format = try ReceiverAudioFormat(bits: bits)
                        _ = try NativeAudioDecoder(format: format)
                        _ = try NativeOpusEncoder(rate: format.sampleRate)
                    }
                    self.log("Native Opus voice encoder/decoder available (16/24/48 kHz)")
                } catch { self.fail("Wireless audio codec unavailable: \(error.localizedDescription)"); return }
            }
            self.log("Receiver display \(configuration.width)×\(configuration.height); audio \(configuration.audioEnabled ? "enabled (PCM/AAC/Opus)" : "off")")
            self.listen(configuration: configuration, identity: identity, port: configuration.port)
        }
    }
    private func listen(configuration: ReceiverConfiguration, identity: AccessoryIdentity, port: UInt16?) {
        let generation = self.generation
        do {
            let candidate = try NWListener(using: .tcp, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            if let airPlayIdentity {
                let features = CarPlayInfo.features(audio: configuration.audioEnabled)
                let txt: [String: String] = ["deviceid": configuration.deviceID,
                    "features": String(format: "0x%x,0x%x", UInt32(truncatingIfNeeded: features), UInt32(truncatingIfNeeded: features >> 32)),
                    "flags": "0x4", "model": "TDSCarKit1,1", "srcvers": "509.11", "protovers": "1.1",
                    "pi": airPlayIdentity.identifier, "pk": airPlayIdentity.signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()]
                candidate.service = NWListener.Service(name: configuration.name, type: "_airplay._tcp", txtRecord: NWTXTRecord(txt))
                candidate.serviceRegistrationUpdateHandler = { [weak self] change in self?.log("Bonjour registration: \(change)") }
            }
            listener = candidate
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate, self.generation == generation, self.listener === candidate else { return }
                switch state {
                case .ready:
                    guard let actualPort = candidate.port?.rawValue else { self.fail("Listener did not receive a port"); return }
                    self.log("Native RTSP listener ready on port \(actualPort)")
                    let advertiseDiscovery = self.airPlayIdentity != nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if advertiseDiscovery {
                            let service = NetService(domain: "local.", type: ReceiverConfiguration.discoveryType,
                                name: configuration.name, port: Int32(actualPort))
                            service.setTXTRecord(NetService.data(fromTXTRecord: [
                                "app": Data("TDSCarKit".utf8), "deviceid": Data(configuration.deviceID.utf8)]))
                            self.discoveryService?.stop(); self.discoveryService = service; service.publish()
                            self.onLog?("Publishing \(configuration.name) on \(ReceiverConfiguration.discoveryType)")
                        }
                        self.onListening?(actualPort)
                    }
                case .failed(let error):
                    if port != nil, case .posix(.EADDRINUSE) = error {
                        self.log("Port \(port!) is occupied; requesting a free port")
                        candidate.cancel(); self.listener = nil
                        self.listen(configuration: configuration, identity: identity, port: nil)
                    } else { self.fail("Listener failed: \(error.localizedDescription)") }
                default: break
                }
            }
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, self.generation == generation, self.listener === candidate,
                      self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                let state = SessionState(credentials: self.airPlayIdentity)
                self.sessions[id] = state
                if case .hostPort(let host, _) = connection.endpoint { state.peerAddress = "\(host)" }
                connection.stateUpdateHandler = { [weak self, weak connection] update in
                    guard let self, let connection else { return }
                    switch update {
                    case .ready:
                        self.log("Incoming control connection")
                        DispatchQueue.main.async { [weak self] in self?.onControlConnected?() }
                        self.receive(connection, id: id, state: state, configuration: configuration, identity: identity)
                    case .failed, .cancelled:
                        state.media?.stop(); self.sessions.removeValue(forKey: id); self.connections.removeValue(forKey: id)
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
            candidate.start(queue: queue)
        } catch let error as NWError {
            if port != nil, case .posix(.EADDRINUSE) = error {
                log("Port \(port!) is occupied; requesting a free port")
                listen(configuration: configuration, identity: identity, port: nil)
            } else { fail("Could not create listener: \(error.localizedDescription)") }
        } catch { fail("Could not create listener: \(error)") }
    }
    private func fail(_ message: String) {
        log(message); stopOnQueue()
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }
    func touch(x: UInt16, y: UInt16, down: Bool) {
        queue.async { [weak self] in self?.sessions.values.first(where: { $0.media != nil })?.media?.touch(x: x, y: y, down: down) }
    }
    private func stopOnQueue() {
        DispatchQueue.main.async { [weak self] in self?.discoveryService?.stop(); self?.discoveryService = nil }
        generation = UUID(); listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sessions.values.forEach { $0.media?.stop() }; sessions.removeAll()
    }
    private final class SessionState {
        var parser = RTSPParser()
        var authenticated = false
        var setup: PairSetup?
        var verify: PairVerify?
        var cipher: ControlCipher?
        var media: CarPlayMediaSession?
        var peerAddress = ""
        init(credentials: AirPlayCredentials?) {
            if let credentials {
                setup = PairSetup(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try credentials.saveController($0, key: $1)
                }
                verify = PairVerify(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try? credentials.controller($0)
                }
            }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, state: SessionState,
                         configuration: ReceiverConfiguration, identity: AccessoryIdentity) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            do {
                if let data, !data.isEmpty {
                    var input = data
                    while true {
                        let plaintext = try state.cipher?.receive(input) ?? input
                        guard let request = try state.parser.append(plaintext, maximumRequests: 1).first else { break }
                        self.log("\(request.method) \(request.target.prefix(100)) [\(request.body.count) bytes]")
                        let response = try self.respond(request, state: state, configuration: configuration, identity: identity)
                        let encoded = response.encoded(for: request)
                        let wire = try state.cipher?.encrypt(encoded) ?? encoded
                        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                            if let error { self?.log("Control write failed: \(error.localizedDescription)"); connection.cancel() }
                        })
                        input = Data()
                        if state.cipher == nil, let keys = state.verify?.keys {
                            // M4 is plaintext. Only subsequent bytes use the negotiated record keys.
                            state.cipher = ControlCipher(readKey: keys.read, writeKey: keys.write)
                            input = state.parser.takeBufferedData()
                            self.log("Pair-verify accepted; encrypted control enabled")
                        }
                    }
                }
                if complete || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, state: state, configuration: configuration, identity: identity) }
            } catch {
                self.log("Control connection rejected: \(error)"); connection.cancel(); self.connections.removeValue(forKey: id)
            }
        }
    }
    private func respond(_ request: RTSPRequest, state: SessionState, configuration: ReceiverConfiguration,
                         identity: AccessoryIdentity) throws -> RTSPResponse {
        switch (request.method, request.target.components(separatedBy: "?")[0]) {
        case ("OPTIONS", _): return RTSPResponse()
        case ("SETUP", _):
            guard state.cipher != nil, state.authenticated, let secret = state.verify?.mediaSecret else {
                throw ProtocolError.malformed("SETUP before verified accessory session")
            }
            if state.media == nil {
                let media = CarPlayMediaSession(queue: queue, secret: secret, peerAddress: state.peerAddress, audioEnabled: configuration.audioEnabled)
                media.onLog = { [weak self] in self?.log($0) }
                media.onVideo = { [weak self] data in
                    guard let self, self.videoSlots.wait(timeout: .now()) == .success else { return }
                    DispatchQueue.main.async { [weak self, videoSlots = self.videoSlots] in
                        defer { videoSlots.signal() }; self?.onVideo?(data)
                    }
                }
                media.onPCM = { [weak self] buffer in self?.onPCM?(buffer) }
                state.media = media
            }
            return RTSPResponse(body: try state.media!.setup(request.body), contentType: "application/x-apple-binary-plist")
        case ("RECORD", _):
            guard state.media != nil else { throw ProtocolError.malformed("RECORD before SETUP") }
            log("CarPlay RECORD accepted; waiting for video")
            return RTSPResponse()
        case ("POST", "/pair-setup"):
            guard state.cipher == nil, let setup = state.setup else { throw ProtocolError.malformed("pair-setup unavailable") }
            let fields = try TLV8.decode(request.body)
            log("Pair-setup state \(fields[6]?.first ?? 0), method \(fields[0]?.first.map(String.init) ?? "absent")")
            let body = try setup.handle(request.body)
            if setup.complete { log("Pair-setup complete; verified controller saved") }
            return RTSPResponse(body: body, contentType: "application/pairing+tlv8")
        case ("POST", "/pair-verify"):
            guard state.cipher == nil, let verify = state.verify else { throw ProtocolError.malformed("pair-verify unavailable") }
            return RTSPResponse(body: try verify.handle(request.body), contentType: "application/pairing+tlv8")
        case ("GET", "/info"), ("POST", "/info"):
            let info = CarPlayInfo.build(configuration)
            return RTSPResponse(body: try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                                contentType: "application/x-apple-binary-plist")
        case ("POST", "/auth-setup"):
            let body = try MFiSAP.respond(to: request.body, identity: identity)
            state.authenticated = true
            log("MFiSAP response generated; awaiting phone acceptance")
            return RTSPResponse(body: body)
        case ("POST", "/feedback"):
            if let feedback = try state.media?.feedback() {
                return RTSPResponse(body: feedback, contentType: "application/x-apple-binary-plist")
            }
            return RTSPResponse()
        case ("POST", "/command"):
            guard state.cipher != nil else { throw ProtocolError.malformed("command before verification") }
            if let command = try PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any] {
                let type = command["type"] as? String ?? "unknown"
                log("CarPlay command: \(type); fields: \(command.keys.sorted().joined(separator: ", "))")
                if type == "modesChanged", let params = command["params"] as? [String: Any] {
                    for resource in params["resources"] as? [[String: Any]] ?? [] {
                        let fields = ["resourceID", "entity", "permanentEntity"].compactMap { key -> String? in
                            guard let value = resource[key] as? NSNumber else { return nil }
                            return "\(key)=\(value)"
                        }
                        log("CarPlay resource: \(fields.joined(separator: ", "))")
                    }
                }

            }
            return RTSPResponse()
        case ("TEARDOWN", _):
            if try state.media?.teardown(request.body) == true { state.media = nil }
            return RTSPResponse()
        default:
            log("Not implemented yet: \(request.method) \(request.target.prefix(80)); no session claimed")
            return RTSPResponse(status: 501, reason: "Not Implemented")
        }
    }
    private func log(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onLog?(message) } }
}
