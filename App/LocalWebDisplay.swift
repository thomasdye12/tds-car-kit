// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import AVFoundation
import VideoToolbox
import CoreImage
import UIKit

/// A small, foreground-only HTTP display. Each request is same-origin and PIN gated.
final class LocalWebDisplay {
    private let queue = DispatchQueue(label: "TDSCarKit.web")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var frame: Data?
    private var hasLoggedFirstFrame = false
    private var receiverState = "ready"
    private var receiverMessage = "Tap Connect CarPlay to start."
    private var audio = Data()
    private var audioRate: UInt32 = 48000
    private var audioChannels: UInt8 = 2
    private let decoder = WebFrameDecoder()
    private(set) var pin = String(format: "%06d", Int.random(in: 0...999999))
    var onTouch: ((UInt16, UInt16, Bool) -> Void)?
    var onLog: ((String) -> Void)?
    var onReady: ((UInt16) -> Void)?
    var onConnect: ((CGSize) -> Void)?
    var size = CGSize(width: 1280, height: 720)

    func start() {
        queue.async { [self] in
            guard self.listener == nil else { return }
            self.pin = String(format: "%06d", Int.random(in: 0...999999))
            do {
                let listener = try NWListener(using: .tcp, on: 8765)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? 8765
                        DispatchQueue.main.async { self.onReady?(port) }
                    case .failed(let error):
                        listener.cancel()
                        if self.listener === listener { self.listener = nil }
                        DispatchQueue.main.async { self.onLog?("Web display unavailable: \(error.localizedDescription)") }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
            } catch { DispatchQueue.main.async { self.onLog?("Web display unavailable: \(error.localizedDescription)") } }
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    func resetStream() { queue.async { self.resetStreamOnQueue() } }
    func setReceiverState(_ state: String, message: String) {
        queue.async { self.receiverState = state; self.receiverMessage = message }
    }
    private func stopOnQueue() {
        listener?.cancel(); listener = nil
        clients.values.forEach { $0.cancel() }; clients.removeAll()
        resetStreamOnQueue()
        receiverState = "ready"; receiverMessage = "Tap Connect CarPlay to start."
    }
    private func resetStreamOnQueue() {
        frame = nil; hasLoggedFirstFrame = false; audio.removeAll(); decoder.reset()
    }
    func receiveVideo(_ accessUnit: Data) {
        decoder.decode(accessUnit) { [weak self] jpeg in
            guard let jpeg else { return }
            self?.queue.async {
                guard let self else { return }
                self.frame = jpeg
                if !self.hasLoggedFirstFrame {
                    self.hasLoggedFirstFrame = true
                    DispatchQueue.main.async { self.onLog?("Browser video frames are ready") }
                }
            }
        }
    }
    func receiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard let planes = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength), channels = min(Int(buffer.format.channelCount), 2)
        guard count > 0, channels > 0 else { return }
        var bytes = Data(count: count * channels * MemoryLayout<Float>.size)
        bytes.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for i in 0..<count { for c in 0..<channels { samples[i * channels + c] = planes[c][i] } }
        }
        let rate = UInt32(buffer.format.sampleRate)
        queue.async {
            self.audioRate = rate; self.audioChannels = UInt8(channels)
            self.audio.append(bytes)
            if self.audio.count > Int(rate) * channels * 4 { self.audio.removeFirst(self.audio.count - Int(rate) * channels * 4) }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 12 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.read(connection, id: id, data: Data()) }
            if case .failed = state { self?.clients.removeValue(forKey: id) }
            if case .cancelled = state { self?.clients.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
    }
    private func read(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, done, error in
            guard let self, error == nil, !done else { connection.cancel(); return }
            var input = data; input.append(chunk ?? Data())
            guard input.count <= 8192 else { self.reply(connection, id: id, status: "413 Payload Too Large"); return }
            guard let range = input.range(of: Data("\r\n\r\n".utf8)) else { self.read(connection, id: id, data: input); return }
            let head = String(decoding: input[..<range.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            guard (0...256).contains(length) else { self.reply(connection, id: id, status: "413 Payload Too Large"); return }
            let body = input[range.upperBound...]
            if body.count < length { self.read(connection, id: id, data: input); return }
            self.handle(head, body: Data(body.prefix(length)), connection: connection, id: id)
        }
    }
    private func handle(_ head: String, body: Data, connection: NWConnection, id: UUID) {
        guard let first = head.components(separatedBy: "\r\n").first else { reply(connection, id: id, status: "400 Bad Request"); return }
        let parts = first.split(separator: " ")
        guard parts.count == 3, let url = URLComponents(string: "http://localhost\(parts[1])"),
              url.queryItems?.first(where: { $0.name == "pin" })?.value == pin else {
            reply(connection, id: id, status: "403 Forbidden"); return
        }
        let path = url.path
        switch (String(parts[0]), path) {
        case ("GET", "/"):
            reply(connection, id: id, content: Data(Self.page.utf8), type: "text/html; charset=utf-8")
        case ("GET", "/state"):
            let state = frame == nil ? receiverState : "streaming"
            let payload = try? JSONSerialization.data(withJSONObject: ["state": state, "message": receiverMessage])
            reply(connection, id: id, content: payload ?? Data(), type: "application/json")
        case ("POST", "/connect"):
            guard receiverState == "ready", let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let width = value["width"] as? Double, let height = value["height"] as? Double,
                  width.isFinite, height.isFinite, (320...4096).contains(width), (240...4096).contains(height),
                  let onConnect else { reply(connection, id: id, status: "409 Conflict"); return }
            receiverState = "starting"; receiverMessage = "Starting CarPlay on the iPhone…"
            DispatchQueue.main.async { onConnect(CGSize(width: width, height: height)) }
            reply(connection, id: id, content: Data("{\"state\":\"starting\"}".utf8), type: "application/json")
        case ("GET", "/frame.jpg"):
            if let frame { reply(connection, id: id, content: frame, type: "image/jpeg") }
            else { reply(connection, id: id, status: "204 No Content") }
        case ("GET", "/audio.pcm"):
            var packet = Data()
            var rate = audioRate.littleEndian
            withUnsafeBytes(of: &rate) { packet.append(contentsOf: $0) }
            packet.append(audioChannels)
            packet.append(audio)
            audio.removeAll(keepingCapacity: true)
            reply(connection, id: id, content: packet, type: "application/octet-stream")
        case ("POST", "/touch"):
            guard let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let x = value["x"] as? Double, let y = value["y"] as? Double,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                  let down = value["down"] as? Bool else { reply(connection, id: id, status: "400 Bad Request"); return }
            let px = UInt16(clamping: Int(x * max(0, size.width - 1)))
            let py = UInt16(clamping: Int(y * max(0, size.height - 1)))
            DispatchQueue.main.async { self.onTouch?(px, py, down) }
            reply(connection, id: id, status: "204 No Content")
        default: reply(connection, id: id, status: "404 Not Found")
        }
    }
    private func reply(_ connection: NWConnection, id: UUID, status: String = "200 OK", content: Data = Data(), type: String = "text/plain") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self'\r\n\r\n"
        connection.send(content: Data(header.utf8) + content, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { connection.cancel(); self?.clients.removeValue(forKey: id) }
        })
    }
    private static let page = #"""
    <!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <meta name="theme-color" content="#080d18"><title>TDS Car Kit display</title>
    <style>[hidden]{display:none!important}html,body{margin:0;width:100%;height:100%;background:#080d18;color:white;font:16px -apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden}main{height:100%;position:relative}header{position:absolute;z-index:2;top:0;left:0;right:0;display:flex;align-items:center;justify-content:space-between;padding:12px 20px;background:#121b2bdd}h1{font-size:17px;margin:0}button{border:0;border-radius:10px;padding:10px 15px;background:#2575f6;color:white;font-weight:700}button:disabled{opacity:.6}#stage{width:100%;height:100%;display:flex;align-items:center;justify-content:center;touch-action:none}img{width:100%;height:100%;object-fit:contain;touch-action:none}#welcome{position:absolute;z-index:1;display:flex;flex-direction:column;align-items:center;gap:16px;text-align:center;padding:28px;max-width:420px}#welcome h2{font-size:clamp(24px,4vw,40px);margin:0}#hint{color:#a6b4cb;line-height:1.5}small{color:#a6b4cb}</style>
    <main><header><div><h1>TDS Car Kit</h1><small>Local CarPlay display</small></div><button id="sound">Enable audio</button></header><div id="stage"><div id="welcome"><h2>Connect CarPlay</h2><div id="hint">Checking the iPhone…</div><button id="connect" hidden>Connect CarPlay</button></div><img id="screen" alt="CarPlay display" hidden></div></main>
    <script>
    const pin=new URLSearchParams(location.search).get('pin'),url=p=>p+'?pin='+encodeURIComponent(pin);
    const img=document.querySelector('#screen'),hint=document.querySelector('#hint'),sound=document.querySelector('#sound'),connect=document.querySelector('#connect'),welcome=document.querySelector('#welcome'),stage=document.querySelector('#stage');
    let context,playAt=0,objectURL;
    sound.onclick=async()=>{context=new (window.AudioContext||window.webkitAudioContext)();await context.resume();sound.textContent='Audio on';sound.disabled=true};
    connect.onclick=async()=>{connect.disabled=true;hint.textContent='Starting CarPlay on the iPhone…';const pixelRatio=window.devicePixelRatio||1,rawWidth=stage.clientWidth*pixelRatio,rawHeight=stage.clientHeight*pixelRatio,scale=Math.min(1,4096/rawWidth,4096/rawHeight),width=Math.round(rawWidth*scale),height=Math.round(rawHeight*scale);try{const r=await fetch(url('/connect'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({width,height})});if(!r.ok)throw Error('Could not start CarPlay. Check the iPhone app.')}catch(e){hint.textContent=e.message;connect.disabled=false}};
    async function state(){try{const r=await fetch(url('/state'),{cache:'no-store'});if(r.status===403)throw Error('This link has expired. Copy the current link from the iPhone.');if(!r.ok)throw Error('Cannot reach the iPhone app.');const value=await r.json();if(value.state==='ready'){welcome.hidden=false;img.hidden=true;connect.hidden=false;connect.disabled=false;hint.textContent=value.message||'Tap Connect CarPlay to start.'}else if(value.state==='starting'){welcome.hidden=false;img.hidden=true;connect.hidden=true;hint.textContent=value.message||'Starting CarPlay…'}else if(value.state==='streaming'){welcome.hidden=true;img.hidden=false}else{welcome.hidden=false;img.hidden=true;connect.hidden=true;hint.textContent=value.message||'Check the iPhone app.'}}catch(e){welcome.hidden=false;img.hidden=true;connect.hidden=true;hint.textContent=e.message}setTimeout(state,500)}state();
    async function video(){try{if(!img.hidden){const r=await fetch(url('/frame.jpg'),{cache:'no-store'});if(r.ok&&r.status!==204){const blob=await r.blob();const next=URL.createObjectURL(blob);img.onload=()=>{if(objectURL)URL.revokeObjectURL(objectURL);objectURL=next};img.onerror=()=>{URL.revokeObjectURL(next);welcome.hidden=false;hint.textContent='Video frame could not be displayed'};img.src=next}}}catch(e){}setTimeout(video,100)}video();
    async function audio(){try{const r=await fetch(url('/audio.pcm'),{cache:'no-store'});if(r.ok&&context){const b=await r.arrayBuffer();if(b.byteLength>5){const d=new DataView(b),rate=d.getUint32(0,true),channels=d.getUint8(4),samples=(b.byteLength-5)/4/channels;if(rate&&channels&&samples){const buffer=context.createBuffer(channels,samples,rate);for(let c=0;c<channels;c++){const out=buffer.getChannelData(c);for(let i=0;i<samples;i++)out[i]=d.getFloat32(5+(i*channels+c)*4,true)}const source=context.createBufferSource();source.buffer=buffer;source.connect(context.destination);playAt=Math.max(context.currentTime+.08,Math.min(playAt,context.currentTime+.4));source.start(playAt);playAt+=buffer.duration}}}}catch(e){}setTimeout(audio,60)}audio();
    function point(e){const r=img.getBoundingClientRect(),natural=img.naturalWidth/img.naturalHeight,box=r.width/r.height;let w=r.width,h=r.height,left=r.left,top=r.top;if(Number.isFinite(natural)){if(natural>box){h=w/natural;top+=(r.height-h)/2}else{w=h*natural;left+=(r.width-w)/2}}return{x:Math.max(0,Math.min(1,(e.clientX-left)/w)),y:Math.max(0,Math.min(1,(e.clientY-top)/h))}}
    async function touch(e,down){if(!img.src)return;e.preventDefault();await fetch(url('/touch'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...point(e),down})}).catch(()=>{})}
    img.onpointerdown=e=>{img.setPointerCapture(e.pointerId);touch(e,true)};img.onpointermove=e=>{if(e.buttons)touch(e,true)};img.onpointerup=e=>touch(e,false);img.onpointercancel=e=>touch(e,false);
    </script></html>
    """#
}

private final class WebFrameDecoder {
    private let queue = DispatchQueue(label: "TDSCarKit.web.video")
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var lastFrame = 0.0
    func reset() { queue.async { self.session.map(VTDecompressionSessionInvalidate); self.session = nil; self.sps = nil; self.pps = nil } }
    func decode(_ accessUnit: Data, completion: @escaping (Data?) -> Void) {
        queue.async {
            guard let units = try? AnnexB.units(in: accessUnit) else { return }
            var picture: [Data] = [], changed = false
            for unit in units {
                switch unit.first! & 0x1f {
                case 7: if unit != self.sps { self.sps = unit; changed = true }
                case 8: if unit != self.pps { self.pps = unit; changed = true }
                default: picture.append(unit)
                }
            }
            guard let sps = self.sps, let pps = self.pps, !picture.isEmpty else { return }
            if changed || self.session == nil {
                self.session.map(VTDecompressionSessionInvalidate); self.session = nil
                var description: CMVideoFormatDescription?
                let status = sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
                    let pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                } }
                guard status == noErr, let description else { return }
                var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
                    guard status == noErr, let image, let ref else { return }
                    let decoder = Unmanaged<WebFrameDecoder>.fromOpaque(ref).takeUnretainedValue()
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - decoder.lastFrame >= 0.1 else { return }
                    decoder.lastFrame = now
                    let ci = CIImage(cvPixelBuffer: image)
                    guard let cg = decoder.context.createCGImage(ci, from: ci.extent),
                          let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.65) else { return }
                    decoder.completion?(jpeg)
                }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                    decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: &callback, decompressionSessionOut: &self.session) == noErr else { return }
            }
            guard let session = self.session, let bytes = try? AnnexB.lengthPrefixed(picture) else { return }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                flags: 0, blockBufferOut: &block) == noErr, let block else { return }
            _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
            var sample: CMSampleBuffer?
            let format = self.formatDescription(sps, pps)
            var sampleSize = bytes.count
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            guard let format, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { return }
            self.completion = completion
            var flags = VTDecodeInfoFlags()
            _ = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &flags)
        }
    }
    private var completion: ((Data?) -> Void)?
    private func formatDescription(_ sps: Data, _ pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        _ = sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
            let pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        } }
        return description
    }
}
