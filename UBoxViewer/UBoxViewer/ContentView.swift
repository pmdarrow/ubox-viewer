import AVFoundation
import SwiftUI
import UBoxStreamLib

/// Shared so the app delegate can trigger cleanup on termination.
final class StreamManager {
    static let shared = StreamManager()
    var client: P4PClient?

    func disconnect() {
        client?.stopStreaming()
        client?.close()
        client = nil
    }
}

struct ContentView: View {
    private static let continueWatchingInterval: TimeInterval = 300
    private static let continueWatchingResponseWindow: TimeInterval = 20

    @State private var uid = Credentials.load()["UBOX_UID"] ?? ""
    @State private var password = Credentials.load()["UBOX_PASSWORD"] ?? ""
    @State private var status = "Disconnected"
    @State private var isConnected = false
    @State private var isConnecting = false
    @State private var nextContinuePromptAt: Date?
    @State private var continuePromptDeadline: Date?
    @State private var continuePromptWorkItem: DispatchWorkItem?
    @State private var continueTimeoutWorkItem: DispatchWorkItem?

    @State private var decoder = H265Decoder()
    @State private var displayLayer = AVSampleBufferDisplayLayer()

    @State private var streamStart: Date?
    @State private var bytesReceived: Int = 0
    @State private var streamMetadata = StreamMetadata()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoView(displayLayer: displayLayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)

                if isConnecting {
                    Color.black.opacity(0.25)
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text(status)
                            .font(.callout)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                if continuePromptDeadline != nil {
                    continueWatchingPrompt
                }
            }

            HStack(spacing: 12) {
                Button(isConnected ? "Disconnect" : "Connect") {
                    if isConnected {
                        disconnect()
                    } else {
                        connect()
                    }
                }
                .disabled(isConnecting)
                .keyboardShortcut(.return, modifiers: .command)
                .fixedSize()

                Spacer()

                if isConnected {
                    streamStats
                } else {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(12)
        }
        .onAppear {
            if !uid.isEmpty && !password.isEmpty {
                connect()
            }
        }
        .onDisappear {
            disconnect()
        }
    }

    private var streamStats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = streamStart.map { context.date.timeIntervalSince($0) } ?? 0
            let bytes = bytesReceived

            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    if let signalTechnologyText = streamMetadata.signalTechnologyText {
                        Text(signalTechnologyText)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    Image(systemName: "cellularbars", variableValue: streamMetadata.signalLevel)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(streamMetadata.signalAccessibilityText)
                .help(streamMetadata.signalAccessibilityText)
                .opacity(streamMetadata.signalOpacity)
                Label(streamMetadata.batteryText, systemImage: streamMetadata.batterySystemImage)
                    .help("Battery")
                Label(streamMetadata.viewersText, systemImage: "person.2")
                    .help("Active viewers")
                Label(formatDuration(elapsed), systemImage: "record.circle")
                Label(formatBytes(bytes), systemImage: "arrow.down.circle")
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var continueWatchingPrompt: some View {
        TimelineView(.animation) { context in
            let timeRemaining = continuePromptDeadline.map {
                max(0, $0.timeIntervalSince(context.date))
            } ?? Self.continueWatchingResponseWindow
            let remaining = Int(ceil(timeRemaining))
            let progress = min(max(timeRemaining / Self.continueWatchingResponseWindow, 0), 1)

            ZStack {
                Color.black.opacity(0.14)

                VStack(spacing: 0) {
                    Text("Still watching?")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 10)

                    Text("To save camera battery and data,\nwe'll disconnect in \(remaining) \(remaining == 1 ? "second" : "seconds").")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(3)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 18)

                    Button {
                        continueWatching()
                    } label: {
                        Text("Continue watching")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(SolidProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 20)

                    continueWatchingProgressBar(progress: progress)
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 306)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.12))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.42), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 14, x: 0, y: 7)
                .scaleEffect(0.85)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func continueWatchingProgressBar(progress: Double) -> some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.36))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.70, blue: 0.08),
                                Color(red: 1.0, green: 0.53, blue: 0.00)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 7)
        .animation(.linear(duration: 0.2), value: progress)
    }

    private func connect() {
        isConnecting = true
        status = "Connecting..."
        clearContinueWatchingPrompt()
        let currentUID = uid
        let currentPassword = password

        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let timebase {
            displayLayer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
        }

        var nextPTS = CMTime.zero
        var frameDuration = CMTime(value: 1, timescale: 15)

        var decodedFrameCount = 0
        decoder.onDecodedFrame = { pixelBuffer in
            decodedFrameCount += 1
            if decodedFrameCount <= 5 {
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                Log.info("Decoded frame #\(decodedFrameCount): \(w)x\(h)")
            }
            if let timebase {
                let now = CMTimebaseGetTime(timebase)
                if nextPTS < now { nextPTS = now }
            }
            let pts = nextPTS
            nextPTS = CMTimeAdd(nextPTS, frameDuration)

            guard let formatDesc = try? CMVideoFormatDescription(imageBuffer: pixelBuffer),
                  let sampleBuffer = try? CMSampleBuffer(
                      imageBuffer: pixelBuffer,
                      formatDescription: formatDesc,
                      sampleTiming: CMSampleTimingInfo(
                          duration: frameDuration,
                          presentationTimeStamp: pts,
                          decodeTimeStamp: .invalid
                      )
                  ) else {
                Log.warning("Failed to create sample buffer for frame #\(decodedFrameCount)")
                return
            }
            displayLayer.enqueue(sampleBuffer)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let c = try P4PClient(
                    uid: currentUID,
                    password: currentPassword,
                    streamType: P4P.streamMain
                )

                guard c.connect(timeout: 30.0) else {
                    DispatchQueue.main.async {
                        status = "Connection failed"
                        isConnecting = false
                    }
                    return
                }

                Log.info("starting stream...")
                var viewerFrameCount = 0
                c.startStreaming { data, frame in
                    viewerFrameCount += 1
                    if viewerFrameCount <= 5 {
                        Log.info("Viewer callback frame #\(viewerFrameCount): \(data.count) bytes, I=\(frame.isIFrame), fps=\(frame.framerate)")
                    }
                    if frame.framerate > 0 {
                        frameDuration = CMTime(value: 1, timescale: Int32(frame.framerate))
                    }
                    decoder.decode(data)
                    DispatchQueue.main.async {
                        bytesReceived = c.bytesReceived
                        streamMetadata.update(from: frame)
                    }
                }

                DispatchQueue.main.async {
                    StreamManager.shared.client = c
                    isConnected = true
                    isConnecting = false
                    let now = Date()
                    streamStart = now
                    scheduleContinueWatchingPrompt(from: now)
                    bytesReceived = 0
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

    private func disconnect(status newStatus: String = "Disconnected") {
        StreamManager.shared.disconnect()
        isConnected = false
        isConnecting = false
        streamStart = nil
        bytesReceived = 0
        streamMetadata = StreamMetadata()
        status = newStatus
        clearContinueWatchingPrompt()

        displayLayer.controlTimebase = nil
        displayLayer.flushAndRemoveImage()
        decoder.reset()
    }

    private func continueWatching() {
        scheduleContinueWatchingPrompt(from: Date())
        status = "Connected"
    }

    private func scheduleContinueWatchingPrompt(from date: Date) {
        clearContinueWatchingPrompt()
        let promptAt = date.addingTimeInterval(Self.continueWatchingInterval)
        nextContinuePromptAt = promptAt

        let workItem = DispatchWorkItem {
            guard isConnected, nextContinuePromptAt == promptAt else { return }
            let deadline = Date().addingTimeInterval(Self.continueWatchingResponseWindow)
            continuePromptDeadline = deadline
            scheduleContinueWatchingTimeout(at: deadline)
        }
        continuePromptWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, promptAt.timeIntervalSinceNow),
            execute: workItem
        )
    }

    private func scheduleContinueWatchingTimeout(at deadline: Date) {
        continueTimeoutWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            guard isConnected, continuePromptDeadline == deadline else { return }
            disconnect(status: "Disconnected automatically")
        }
        continueTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow),
            execute: workItem
        )
    }

    private func clearContinueWatchingPrompt() {
        continuePromptWorkItem?.cancel()
        continueTimeoutWorkItem?.cancel()
        continuePromptWorkItem = nil
        continueTimeoutWorkItem = nil
        nextContinuePromptAt = nil
        continuePromptDeadline = nil
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1_000_000 {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        } else if bytes < 1_000_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
        }
    }
}

private struct StreamMetadata {
    var signalBars: Int?
    var batteryPercent: Int?
    var isCharging = false
    var activeViewers: Int?

    var signalLevel: Double {
        guard let signalBars else { return 0.0 }
        return Double(signalBars) / 5.0
    }

    var signalOpacity: Double {
        signalBars == nil ? 0.35 : 1.0
    }

    var signalTechnologyText: String? {
        signalBars == nil ? nil : "4G"
    }

    var signalAccessibilityText: String {
        guard let signalBars else { return "Cell signal unknown" }
        return "4G signal \(signalBars) of 5"
    }

    var batteryText: String {
        guard let batteryPercent else { return "--%" }
        return "\(batteryPercent)%"
    }

    var viewersText: String {
        guard let activeViewers else { return "--" }
        return String(activeViewers)
    }

    var batterySystemImage: String {
        guard let batteryPercent else { return "battery.0" }
        if isCharging { return "battery.100.bolt" }
        switch batteryPercent {
        case 76...:
            return "battery.100"
        case 51...75:
            return "battery.75"
        case 26...50:
            return "battery.50"
        case 1...25:
            return "battery.25"
        default:
            return "battery.0"
        }
    }

    mutating func update(from frame: AVFrame) {
        activeViewers = frame.activeViewers
        if let batteryPercent = frame.batteryPercent {
            self.batteryPercent = batteryPercent
            isCharging = frame.isCharging ?? false
        }
        if let cellularSignalBars = frame.cellularSignalBars {
            signalBars = cellularSignalBars
        }
    }
}

private enum Credentials {
    static func load() -> [String: String] {
        // Walk up from the source file, checking each directory for .credentials
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let file = dir.appendingPathComponent(".credentials")
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                return parse(contents)
            }
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

private struct SolidProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.18), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                }
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
