import ArgumentParser
import Foundation
import UBoxStreamLib

enum StreamQuality: String, ExpressibleByArgument, CaseIterable {
    case hd, sd

    var streamType: UInt8 {
        switch self {
        case .hd: return P4P.streamMain
        case .sd: return P4P.streamSub
        }
    }
}

@main
struct UBoxStream: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ubox-stream",
        abstract: "Connect to UBIA camera and dump video stream"
    )

    @Option(name: .long, help: "Camera UID")
    var uid: String

    @Option(name: .long, help: "Device password from API")
    var password: String

    @Option(name: .long, help: "Device username (default: admin)")
    var username: String = "admin"

    @Option(
        name: [.customShort("q"), .long],
        help: "Stream quality: hd or sd (default: sd)"
    )
    var quality: StreamQuality = .sd

    @Option(
        name: [.customShort("o"), .long],
        help: "Output file path (default: output.h265, or output.mp4 with --mp4)"
    )
    var output: String?

    @Flag(
        name: .long,
        help: "Remux the output to MP4 after recording (requires ffmpeg)"
    )
    var mp4 = false

    @Option(
        name: .customLong("raw-dump"),
        help: "Also dump raw KCP data for debugging"
    )
    var rawDump: String?

    @Option(
        name: [.customShort("d"), .long],
        help: "Recording duration in seconds (default: 30)"
    )
    var duration: Double = 30.0

    @Option(
        name: [.customShort("t"), .long],
        help: "Connection timeout in seconds (default: 30)"
    )
    var timeout: Double = 30.0

    @Flag(
        name: [.customShort("v"), .long],
        help: "Enable debug logging"
    )
    var verbose = false

    mutating func run() throws {
        Log.level = verbose ? .debug : .info

        let mp4Path: String? = mp4
            ? (output ?? "output.mp4")
            : nil
        let h265Path: String
        if let mp4Path {
            let base = (mp4Path as NSString).deletingPathExtension
            h265Path = base + ".h265"
        } else {
            h265Path = output ?? "output.h265"
        }

        let client = try P4PClient(
            uid: uid, password: password,
            username: username, streamType: quality.streamType
        )

        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(
            signal: SIGINT, queue: .main
        )
        sigintSource.setEventHandler {
            Log.info("Interrupted")
            client.close()
            Foundation.exit(0)
        }
        sigintSource.resume()

        guard client.connect(timeout: timeout) else {
            Log.error("Failed to connect to camera \(uid)")
            throw ExitCode.failure
        }

        client.startVideo()
        client.recvLoop(
            outputFile: h265Path,
            rawDump: rawDump,
            duration: duration
        )
        client.close()

        let attrs = try? FileManager.default.attributesOfItem(atPath: h265Path)
        let fileSize = attrs?[.size] as? Int ?? 0
        guard fileSize > 0 else {
            Log.error("No video data received")
            throw ExitCode.failure
        }

        if let mp4Path {
            remuxToMP4(
                h265Path: h265Path,
                mp4Path: mp4Path,
                framerate: client.reportedFramerate
            )
        }

        Log.info("Done.")
    }

    private func remuxToMP4(
        h265Path: String, mp4Path: String, framerate: UInt8
    ) {
        Log.info("Remuxing to \(mp4Path) ...")

        let fps = String(framerate > 0 ? framerate : 15)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y",
            "-r", fps,
            "-f", "hevc", "-i", h265Path,
            "-c:v", "hevc_videotoolbox", "-q:v", "65",
            "-tag:v", "hvc1",
            "-movflags", "+faststart",
            mp4Path,
        ]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                Log.info("MP4 written to \(mp4Path)")
            } else {
                let errData = errPipe.fileHandleForReading
                    .readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                Log.error("ffmpeg failed: \(errStr)")
            }
        } catch {
            Log.error("ffmpeg not found — install it to use --mp4")
        }
    }
}
