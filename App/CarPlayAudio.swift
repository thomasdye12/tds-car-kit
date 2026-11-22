// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import CryptoKit
import Darwin
import Network

private final class AudioDatagramPort {
    let port: UInt16
    private var source: DispatchSourceRead?
    var onPacket: ((Data) -> Void)?
    init(queue: DispatchQueue, peerAddress: String) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var receiveBuffer: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var allowed = in_addr()
        guard inet_pton(AF_INET, peerAddress, &allowed) == 1 else { close(fd); throw ProtocolError.malformed("audio peer") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: address.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue); self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Bound the work per dispatch so media cannot starve control traffic.
            var bytes = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<32 {
                var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let length = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, 65536, 0, $0, &size) } }
                guard length > 0 else { break }
                guard peer.sin_addr.s_addr == allowed.s_addr else { continue }
                self.onPacket?(Data(bytes.prefix(length)))
            }
        }
        source.setCancelHandler { close(fd) }; source.resume()
    }
    func stop() { source?.cancel(); source = nil; onPacket = nil }
    deinit { stop() }
}

final class CarPlayAudio {
    let dataPort: UInt16
    let controlPort: UInt16
    let format: ReceiverAudioFormat
    let connectionID: UInt64
    private let queue: DispatchQueue
    private let data: AudioDatagramPort
    private let control: AudioDatagramPort
    private let cipher: AudioStream
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let output: AVAudioFormat
    private let decoder: NativeAudioDecoder
    private var microphone: NativeMicrophone?
    private var queuedFrames = 0
    private var active = true
    private var playing = false
    private var rejected = 0
    private var firstTimestamp: UInt32?
    private var lastTimestamp: UInt32?
    private var buffering = true
    private var packets = 0
    private var latePackets = 0
    private var overflowPackets = 0
    private var underruns = 0
    private var nextStatistics = 0.0
    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let renderQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "TDSCarKit.audio", qos: .userInteractive)
        queue.setSpecific(key: queueKey, value: true)
        return queue
    }()
    // Audio decoding never blocks the video/RTSP queue. All streams share this queue.
    private static var playingStreams = 0
    var onLog: ((String) -> Void)?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    init(queue: DispatchQueue, secret: SymmetricKey, peerAddress: String, connectionID: UInt64, format: ReceiverAudioFormat, microphonePort: UInt16? = nil) throws {
        self.queue = Self.renderQueue; self.connectionID = connectionID; self.format = format
        decoder = try NativeAudioDecoder(format: format)
        output = decoder.output
        cipher = AudioStream(secret: secret, connectionID: connectionID)
        data = try AudioDatagramPort(queue: Self.renderQueue, peerAddress: peerAddress)
        control = try AudioDatagramPort(queue: Self.renderQueue, peerAddress: peerAddress)
        dataPort = data.port; controlPort = control.port
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: output)
        if let microphonePort, !format.isAAC, format.channels == 1 {
            microphone = NativeMicrophone(secret: secret, connectionID: connectionID, address: peerAddress, port: microphonePort, format: format)
        }
        data.onPacket = { [weak self] in self?.receive($0) }
    }
    private func receive(_ wire: Data) {
        guard active else { return }
        do {
            let packet = try cipher.receive(wire)
            // Decode every accepted compressed packet to preserve the codec's overlap state.
            packets += 1
            if let lastTimestamp, Int32(bitPattern: packet.timestamp &- lastTimestamp) <= 0 { latePackets += 1; return }
            lastTimestamp = packet.timestamp
            guard let buffer = try decoder.decode(packet.samples) else { return }
            let frames = Int(buffer.frameLength)
            guard queuedFrames + frames <= format.sampleRate * 2 else { overflowPackets += 1; return }
            onPCM?(buffer)
            if !playing {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                // Activate recording only for a negotiated voice uplink.
                try session.setCategory(microphone == nil ? .playback : .playAndRecord, mode: .default, options: microphone == nil ? [] : [.defaultToSpeaker])
                try session.setActive(true)
                #endif
                do { try engine.start() } catch {
                    #if os(iOS)
                    if Self.playingStreams == 0 { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
                    #endif
                    throw error
                }
                playing = true; Self.playingStreams += 1
                if let microphone {
                    microphone.onLog = onLog
                    DispatchQueue.main.async { microphone.start() }
                }
                firstTimestamp = packet.timestamp
                onLog?("Native \(format.name) playback started: \(format.sampleRate) Hz, \(format.channels) channel(s)")
                #if os(iOS)
                onLog?("Audio output route: \(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))")
                #endif
            }
            queuedFrames += frames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.active else { return }
                    self.queuedFrames = max(0, self.queuedFrames - frames)
                    if self.queuedFrames == 0, !self.buffering {
                        self.player.pause(); self.buffering = true; self.underruns += 1
                    }
                }
            }
            let prebuffer = format.sampleRate * (format.isAAC ? 180 : 40) / 1000
            if buffering, queuedFrames >= prebuffer {
                player.play(); buffering = false
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextStatistics {
                nextStatistics = now + 5
                onLog?("Audio health: packets=\(packets), queued=\(queuedFrames * 1000 / format.sampleRate)ms, underruns=\(underruns), late=\(latePackets), overflow=\(overflowPackets), rejected=\(rejected)")
            }

        } catch {
            rejected += 1
            if rejected <= 3 { onLog?("Audio packet rejected: \(error.localizedDescription)") }
        }
    }
    func feedback(type: Int, ntp: UInt64) -> [String: Any] {
        queue.sync {
            var info: [String: Any] = ["type": type, "sampleRate": format.sampleRate]
            if let firstTimestamp, let render = player.lastRenderTime,
               let position = player.playerTime(forNodeTime: render) {
                info["sampleTime"] = NSNumber(value: firstTimestamp &+ UInt32(truncatingIfNeeded: max(0, position.sampleTime)))
                info["timestamp"] = NSNumber(value: ntp); info["streamConnectionID"] = NSNumber(value: connectionID)
            }
            return info
        }
    }
    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }
    private func stopOnQueue() {
        guard active else { return }; active = false
        if let microphone { DispatchQueue.main.async { microphone.stop() } }; microphone = nil
        data.stop(); control.stop(); player.stop(); engine.stop(); queuedFrames = 0
        if playing {
            playing = false; Self.playingStreams -= 1
            #if os(iOS)
            if Self.playingStreams == 0 { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            #endif
        }
    }
    deinit { stop() }
}

/// Converts one authenticated RTP payload to native Float32 PCM.
/// AAC payloads are raw access units, not ADTS containers.
final class NativeAudioDecoder {
    let output: AVAudioFormat
    private let format: ReceiverAudioFormat
    private var converter: AVAudioConverter?
    private var compressed: AVAudioFormat?
    init(format: ReceiverAudioFormat) throws {
        self.format = format
        output = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate), channels: AVAudioChannelCount(format.channels))!
        if format.isAAC || format.isOpus {
            var description = AudioStreamBasicDescription(mSampleRate: Double(format.sampleRate), mFormatID: format.isOpus ? kAudioFormatOpus : kAudioFormatMPEG4AAC,
                mFormatFlags: format.isOpus ? 0 : 2, mBytesPerPacket: 0, mFramesPerPacket: format.isOpus ? UInt32(format.sampleRate / 50) : 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 0, mReserved: 0)
            guard let input = AVAudioFormat(streamDescription: &description), let codec = AVAudioConverter(from: input, to: output) else {
                throw ProtocolError.malformed("\(format.name) decoder unavailable")
            }
            if format.isAAC { codec.magicCookie = Data(format.sampleRate == 44100 ? [0x12, 0x10] : [0x11, 0x90]) }
            codec.primeMethod = .none
            compressed = input; converter = codec
        }
    }
    func decode(_ payload: Data) throws -> AVAudioPCMBuffer? {
        guard !payload.isEmpty, payload.count <= 65507 else { throw ProtocolError.malformed("audio payload size") }
        if let converter, let compressed {
            let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: payload.count)
            input.packetCount = 1; input.byteLength = UInt32(payload.count)
            payload.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
            input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: format.isOpus ? 0 : 1024, mDataByteSize: UInt32(payload.count))
            guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: format.isOpus ? AVAudioFrameCount(format.sampleRate * 120 / 1000) : 1024) else { throw ProtocolError.malformed("AAC output buffer") }
            var supplied = false, error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? NSError(domain: "TDSAudio", code: 1) }
            return pcm.frameLength > 0 ? pcm : nil
        }
        let frameBytes = format.channels * 2
        guard payload.count % frameBytes == 0 else { throw ProtocolError.malformed("PCM frame size") }
        let frames = payload.count / frameBytes
        guard frames <= format.sampleRate / 4,
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)), let planes = buffer.floatChannelData else {
            throw ProtocolError.malformed("PCM output buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        payload.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<format.channels {
                    let index = (frame * format.channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                    planes[channel][frame] = Float(sample) / 32768
                }
            }
        }
        return buffer
    }
}

/// On-demand mono PCM/Opus capture for a negotiated voice uplink. All state is main-thread.
/// Music streams never request microphone permission or activate recording.
private final class NativeMicrophone {
    private let engine = AVAudioEngine()
    private let packetizer: MicrophonePacketizer
    private let connection: NWConnection
    private let rate: Int
    private let format: ReceiverAudioFormat
    private var opusEncoder: NativeOpusEncoder?
    private let slots = DispatchSemaphore(value: 4)
    private var converter: AVAudioConverter?
    private var active = true
    private var installedTap = false
    private var pending = Data()
    private var failures = 0
    var onLog: ((String) -> Void)?
    init(secret: SymmetricKey, connectionID: UInt64, address: String, port: UInt16, format: ReceiverAudioFormat) {
        self.rate = format.sampleRate; self.format = format
        packetizer = MicrophonePacketizer(secret: secret, connectionID: connectionID)
        connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
    }
    func start() {
        guard active else { return }
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                if granted { self.beginCapture() }
                else { self.onLog?("Microphone permission denied; voice input is unavailable") }
            }
        }
        #else
        onLog?("Microphone capture requires the iPhone/iPad target")
        #endif
    }
    private func beginCapture() {
        do {
            if format.isOpus { opusEncoder = try NativeOpusEncoder(rate: rate) }
            let input = engine.inputNode.outputFormat(forBus: 0)
            guard input.sampleRate > 0, input.channelCount > 0,
                  let output = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
                  let converter = AVAudioConverter(from: input, to: output) else { throw ProtocolError.malformed("microphone format") }
            self.converter = converter
            connection.start(queue: .main)
            let slots = self.slots
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
                guard slots.wait(timeout: .now()) == .success else { return }
                guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { slots.signal(); return }
                copy.frameLength = buffer.frameLength
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for index in 0..<source.count {
                    if let src = source[index].mData, let dst = target[index].mData {
                        dst.copyMemory(from: src, byteCount: Int(source[index].mDataByteSize))
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    defer { slots.signal() }
                    guard let self, self.active else { return }
                    self.send(copy)
                }
            }
            installedTap = true
            try engine.start()
            onLog?("\(format.name) microphone started: \(rate) Hz mono")
        } catch { onLog?("Microphone could not start: \(error.localizedDescription)"); stop() }
    }
    private func send(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        do {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * Double(rate) / input.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? NSError(domain: "TDSMicrophone", code: 1) }
            guard let samples = output.floatChannelData?[0] else { return }
            for index in 0..<Int(output.frameLength) {
                let scaled = samples[index].isFinite ? max(-32768, min(32767, samples[index] * 32768)) : 0
                let sample = UInt16(bitPattern: Int16(scaled))
                pending.append(UInt8(truncatingIfNeeded: sample >> 8)); pending.append(UInt8(truncatingIfNeeded: sample))
            }
            let frames = rate / 50, bytes = frames * 2
            while pending.count >= bytes {
                let pcm = Data(pending.prefix(bytes))
                pending.removeFirst(bytes)
                let payload: Data
                if let opusEncoder {
                    guard let encoded = try opusEncoder.encode(pcm) else { continue }
                    payload = encoded
                } else { payload = pcm }
                let wire = try packetizer.seal(payload, frames: UInt32(frames))
                connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.stop() }
                })
            }
        } catch {
            failures += 1
            if failures <= 3 { onLog?("Microphone conversion failed: \(error.localizedDescription)") }
        }
    }
    func stop() {
        guard active else { return }; active = false
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        engine.stop(); connection.cancel(); converter = nil; pending.removeAll()
    }
}

/// One 20-ms mono voice packet. Uses Apple's codec, with no Ogg/container header.
final class NativeOpusEncoder {
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let compressed: AVAudioFormat
    private let frames: Int
    init(rate: Int) throws {
        frames = rate / 50
        pcm = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &description),
              let codec = AVAudioConverter(from: pcm, to: format) else { throw ProtocolError.malformed("Opus encoder unavailable") }
        compressed = format; converter = codec
        converter.primeMethod = .none
        converter.bitRate = rate == 48000 ? 64000 : 32000
    }
    func encode(_ bigEndianPCM: Data) throws -> Data? {
        guard bigEndianPCM.count == frames * 2,
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else {
            throw ProtocolError.malformed("Opus microphone frame size")
        }
        input.frameLength = AVAudioFrameCount(frames)
        bigEndianPCM.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<frames {
                input.floatChannelData![0][index] = Float(Int16(bitPattern: UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1]))) / 32768
            }
        }
        let packet = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: 4096)
        var supplied = false, error: NSError?
        let status = converter.convert(to: packet, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? NSError(domain: "TDSOpus", code: 1) }
        guard packet.packetCount > 0, packet.byteLength > 0 else { return nil }
        return Data(bytes: packet.data, count: Int(packet.byteLength))
    }
}
