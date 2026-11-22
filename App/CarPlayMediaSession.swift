// SPDX-License-Identifier: GPL-3.0-or-later
// Native event/video session adapted from PlayPort's AirPlaySession and media engine.
import Foundation
import CryptoKit
import AVFoundation

final class CarPlayMediaSession {
    private let queue: DispatchQueue
    private let secret: SymmetricKey
    private let peerAddress: String
    private var eventListener: MediaTCPListener?
    private var videoListener: MediaTCPListener?
    private var event: MediaTCPConnection?
    private var video: MediaTCPConnection?
    private var timing: MediaTiming?
    private var audio: [Int: CarPlayAudio] = [:]
    private let audioEnabled: Bool
    private var eventCipher: ControlCipher?
    private var eventParser = RTSPParser(allowResponses: true)
    private var screen: ScreenStream?
    private var cseq = 0
    private var videoPackets = 0
    var onLog: ((String) -> Void)?
    var onVideo: ((Data) -> Void)?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    init(queue: DispatchQueue, secret: SymmetricKey, peerAddress: String, audioEnabled: Bool) {
        self.queue = queue; self.secret = secret; self.peerAddress = peerAddress; self.audioEnabled = audioEnabled
    }
    func setup(_ data: Data) throws -> Data {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ProtocolError.malformed("SETUP property list")
        }
        onLog?("SETUP fields: \(values.keys.sorted().joined(separator: ", "))")
        var response: [String: Any] = [:]
        if let streams = values["streams"] as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for stream in streams {
                guard let type = stream["type"] as? NSNumber else { throw ProtocolError.malformed("stream type") }
                onLog?("Requested media stream \(type), audio format \((stream["audioFormat"] as? NSNumber)?.stringValue ?? "none")")
                if [100, 101, 102].contains(type.intValue), audioEnabled {
                    guard eventListener != nil, let connectionID = stream["streamConnectionID"] as? NSNumber,
                          let bits = stream["audioFormat"] as? NSNumber else { throw ProtocolError.malformed("audio setup fields") }
                    let format = try ReceiverAudioFormat(bits: bits.uint64Value)
                    let audioType = (stream["audioType"] as? String ?? "").lowercased()
                    let requestsMicrophone = type.intValue == 100 && ["telephony", "speechrecognition", "default"].contains(audioType)
                        && ((stream["input"] as? Bool) == true || (stream["dataPort"] as? NSNumber)?.intValue ?? 0 > 0)
                    let microphonePort = requestsMicrophone ? (stream["dataPort"] as? NSNumber).flatMap { UInt16(exactly: $0.intValue) }.flatMap { $0 > 0 ? $0 : nil } : nil
                    audio.removeValue(forKey: type.intValue)?.stop()
                    let output = try CarPlayAudio(queue: queue, secret: secret, peerAddress: peerAddress,
                        connectionID: connectionID.uint64Value, format: format, microphonePort: microphonePort)
                    output.onLog = { [weak self] in self?.onLog?($0) }
                    output.onPCM = { [weak self] in self?.onPCM?($0) }
                    audio[type.intValue] = output
                    replies.append(["type": type, "dataPort": output.dataPort, "controlPort": output.controlPort,
                                    "streamConnectionID": connectionID])
                    onLog?("Audio stream \(type) ready: \(format.name) \(format.sampleRate) Hz / \(format.channels) channels")
                    continue
                }
                guard type.intValue == 110, let connectionID = stream["streamConnectionID"] as? NSNumber else {
                    throw ProtocolError.malformed("unsupported media stream type \(type)")
                }
                guard eventListener != nil else { throw ProtocolError.malformed("screen before initial SETUP") }
                video?.stop(); video = nil; videoListener?.stop()
                screen = ScreenStream(secret: secret, connectionID: connectionID.uint64Value)
                videoPackets = 0
                let listener = try MediaTCPListener(queue: queue, peerAddress: peerAddress); videoListener = listener
                listener.onConnection = { [weak self] connection in
                    guard let self, self.video == nil else { connection.stop(); return }
                    self.video = connection; self.onLog?("Video TCP channel connected")
                    connection.onBytes = { [weak self] bytes in
                        guard let self, let screen = self.screen else { return }
                        do {
                            for unit in try screen.append(bytes) {
                                self.videoPackets += 1
                                if self.videoPackets <= 2 { self.onLog?("Decoded video access unit \(self.videoPackets) (\(unit.count) bytes)") }
                                self.onVideo?(unit)
                            }
                        } catch { self.onLog?("Video rejected: \(error)"); throw error }
                    }
                    connection.onClose = { [weak self] in self?.video = nil; self?.onLog?("Video channel closed") }
                    connection.start()
                }
                replies.append(["type": 110, "dataPort": listener.port])
                onLog?("Video listener ready on port \(listener.port)")
            }
            response["streams"] = replies
        } else {
            guard eventListener == nil else { throw ProtocolError.malformed("duplicate initial SETUP") }
            let timingPort = (values["timingPort"] as? NSNumber)?.intValue ?? 0
            guard (0...65535).contains(timingPort) else { throw ProtocolError.malformed("timing port") }
            timing = try MediaTiming(queue: queue, peerAddress: peerAddress, peerPort: UInt16(timingPort))
            let listener = try MediaTCPListener(queue: queue, peerAddress: peerAddress); eventListener = listener
            listener.onConnection = { [weak self] connection in self?.acceptEvent(connection) }
            response = ["eventPort": listener.port, "timingPort": timing!.port, "enabledFeatures": ["viewAreas"]]
            onLog?("Event/timing listeners ready: \(listener.port)/\(timing!.port)")
        }
        return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
    }
    private func acceptEvent(_ connection: MediaTCPConnection) {
        guard event == nil else { connection.stop(); return }
        event = connection
        eventCipher = ControlCipher(readKey: PairVerify.derive(secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
            writeKey: PairVerify.derive(secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
        onLog?("Encrypted event channel connected")
        connection.onBytes = { [weak self, weak connection] bytes in
            guard let self, let connection, let cipher = self.eventCipher else { return }
            for request in try self.eventParser.append(cipher.receive(bytes)) {
                if request.method.hasPrefix("RTSP/") || request.method.hasPrefix("HTTP/") { continue }
                try connection.send(cipher.encrypt(RTSPResponse().encoded(for: request)))
            }
        }
        connection.onClose = { [weak self] in self?.event = nil; self?.eventCipher = nil; self?.onLog?("Event channel closed") }
        connection.start()
    }
    func touch(x: UInt16, y: UInt16, down: Bool) {
        guard let event, let eventCipher else { return }
        do {
            let report = Data([0, down ? 1 : 0, UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8),
                UInt8(truncatingIfNeeded: y), UInt8(truncatingIfNeeded: y >> 8), 1, 0, 0, 0, 0, 0])
            let body = try PropertyListSerialization.data(fromPropertyList: ["type": "hidSendReport", "uuid": "2a2a2a2a", "hidReport": report], format: .binary, options: 0)
            cseq += 1
            let header = "POST /command RTSP/1.0\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: \(body.count)\r\nCSeq: \(cseq)\r\n\r\n"
            try event.send(eventCipher.encrypt(Data(header.utf8) + body))
        } catch { onLog?("Touch write failed: \(error)"); event.stop() }
    }
    func stop() {
        audio.values.forEach { $0.stop() }; audio.removeAll()
        eventListener?.stop(); videoListener?.stop(); event?.stop(); video?.stop(); timing?.stop()
        eventListener = nil; videoListener = nil; event = nil; video = nil; timing = nil; screen = nil; eventCipher = nil
    }
    func feedback() throws -> Data? {
        guard !audio.isEmpty, let timing else { return nil }
        let streams = audio.map { $0.value.feedback(type: $0.key, ntp: timing.timestamp()) }
        return try PropertyListSerialization.data(fromPropertyList: ["streams": streams], format: .binary, options: 0)
    }
    /// A stream-specific teardown must not terminate the other live streams.
    func teardown(_ body: Data) throws -> Bool {
        guard !body.isEmpty, let values = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let streams = values["streams"] as? [[String: Any]] else { stop(); return true }
        for stream in streams {
            guard let type = stream["type"] as? NSNumber else { continue }
            if type.intValue == 110 { video?.stop(); video = nil; videoListener?.stop(); videoListener = nil; screen = nil }
            audio.removeValue(forKey: type.intValue)?.stop()
        }
        return false
    }
    deinit { stop() }
}
