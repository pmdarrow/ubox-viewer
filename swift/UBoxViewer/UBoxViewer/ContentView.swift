import AVFoundation
import SwiftUI
import UBoxStreamLib

struct ContentView: View {
    @State private var uid = ProcessInfo.processInfo.environment["UBOX_UID"] ?? ""
    @State private var password = ProcessInfo.processInfo.environment["UBOX_PASSWORD"] ?? ""
    @State private var quality: UInt8 = P4P.streamMain
    @State private var status = "Disconnected"
    @State private var isConnected = false
    @State private var isConnecting = false

    @State private var client: P4PClient?
    @State private var parser = H265Parser()
    @State private var displayLayer = AVSampleBufferDisplayLayer()

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
    }

    private func connect() {
        isConnecting = true
        status = "Connecting..."
        let currentUID = uid
        let currentPassword = password
        let currentQuality = quality

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
                    let samples = parser.parse(data)
                    for sample in samples {
                        DispatchQueue.main.async {
                            displayLayer.enqueue(sample)
                        }
                    }
                }

                DispatchQueue.main.async {
                    client = c
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
        isConnected = false
        status = "Disconnected"

        displayLayer.flushAndRemoveImage()
    }
}
