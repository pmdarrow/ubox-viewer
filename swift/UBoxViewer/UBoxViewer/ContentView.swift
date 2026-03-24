import AVFoundation
import SwiftUI
import UBoxStreamLib

struct ContentView: View {
    @State private var uid = Credentials.load()["UBOX_UID"] ?? ""
    @State private var password = Credentials.load()["UBOX_PASSWORD"] ?? ""
    @State private var quality: UInt8 = P4P.streamMain
    @State private var status = "Disconnected"
    @State private var isConnected = false
    @State private var isConnecting = false

    @State private var client: P4PClient?
    @State private var decoder = H265Decoder()
    @State private var displayLayer = AVSampleBufferDisplayLayer()
    @State private var pacer: FramePacer?

    var body: some View {
        VStack(spacing: 0) {
            VideoView(displayLayer: displayLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            HStack(spacing: 12) {
                TextField("Camera UID", text: $uid)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Picker("Quality", selection: $quality) {
                    Text("HD").tag(P4P.streamMain)
                    Text("SD").tag(P4P.streamSub)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)

                Button(isConnected ? "Disconnect" : "Connect") {
                    if isConnected {
                        disconnect()
                    } else {
                        connect()
                    }
                }
                .disabled(isConnecting || (!isConnected && (uid.isEmpty || password.isEmpty)))
                .keyboardShortcut(.return, modifiers: .command)

                Text(status)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(12)
        }
        .onAppear {
            if !uid.isEmpty && !password.isEmpty {
                connect()
            }
        }
    }

    private func connect() {
        isConnecting = true
        status = "Connecting..."
        let currentUID = uid
        let currentPassword = password
        let currentQuality = quality

        let p = FramePacer(displayLayer: displayLayer)

        decoder.onDecodedFrame = { pixelBuffer in
            p.enqueue(pixelBuffer)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let c = try P4PClient(
                    uid: currentUID,
                    password: currentPassword,
                    streamType: currentQuality
                )

                guard c.connect(timeout: 30.0) else {
                    DispatchQueue.main.async {
                        status = "Connection failed"
                        isConnecting = false
                    }
                    return
                }

                c.startVideo()
                c.startStreaming { data, frame in
                    if frame.framerate > 0 {
                        p.start(fps: Double(frame.framerate))
                    }
                    decoder.decode(data)
                }

                DispatchQueue.main.async {
                    client = c
                    pacer = p
                    isConnected = true
                    isConnecting = false
                    status = "Connected"
                }
            } catch {
                DispatchQueue.main.async {
                    status = "Error: \(error.localizedDescription)"
                    isConnecting = false
                }
            }
        }
    }

    private func disconnect() {
        client?.stopStreaming()
        client?.close()
        client = nil
        pacer?.stop()
        pacer = nil
        isConnected = false
        status = "Disconnected"

        displayLayer.flushAndRemoveImage()
        decoder.reset()
    }
}

/// Smooths jittery frame delivery by queuing decoded frames and presenting
/// them at a fixed interval tied to the camera's framerate.
private final class FramePacer {
    private let displayLayer: AVSampleBufferDisplayLayer
    private var queue: [CVPixelBuffer] = []
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var started = false
    private let maxQueueSize = 6

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    /// Thread-safe, idempotent — only the first call actually creates the timer.
    func start(fps: Double) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        let interval = 1.0 / fps
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.presentNext() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        started = false
        queue.removeAll()
        lock.unlock()
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        while queue.count >= maxQueueSize { queue.removeFirst() }
        queue.append(pixelBuffer)
        lock.unlock()
    }

    private func presentNext() {
        lock.lock()
        guard !queue.isEmpty else { lock.unlock(); return }
        let pixelBuffer = queue.removeFirst()
        lock.unlock()

        guard let formatDesc = try? CMVideoFormatDescription(imageBuffer: pixelBuffer),
              let sampleBuffer = try? CMSampleBuffer(
                  imageBuffer: pixelBuffer,
                  formatDescription: formatDesc,
                  sampleTiming: CMSampleTimingInfo(
                      duration: .invalid,
                      presentationTimeStamp: .invalid,
                      decodeTimeStamp: .invalid
                  )
              ) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) as? [NSMutableDictionary]
        attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        displayLayer.enqueue(sampleBuffer)
    }
}

private enum Credentials {
    static func load() -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var dir = url
        for _ in 0..<5 {
            let file = dir.appendingPathComponent(".credentials")
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                return parse(contents)
            }
            dir = dir.deletingLastPathComponent()
        }
        return [:]
    }

    private static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eq])
                let val = String(trimmed[trimmed.index(after: eq)...])
                result[key] = val
            }
        }
        return result
    }
}
