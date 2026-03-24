/// UBIA P4P protocol client — connects to a camera via relay and receives video.
///
/// Connection flow:
///   1. Send query to master servers (m1-m6.ubianet.com:10240)
///   2. Parse response for VPG relay server list
///   3. Send relay wakeup to VPG servers (:20001)
///   4. Wait for wakeup response
///   5. Send relay stream request
///   6. Parse response for relay data endpoint IP:port
///   7. Send knock to relay endpoint
///   8. Exchange keepalives, start video via AV control
///   9. Receive KCP video data, parse RDT blocks, output clean H.265
import Foundation
import Darwin

enum P4PError: LocalizedError {
    case socketCreationFailed
    case noMasterServersResolved
    case connectionTimeout(String)
    case noVideoData

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Failed to create UDP socket"
        case .noMasterServersResolved:
            return "No master servers could be resolved"
        case .connectionTimeout(let phase):
            return "Connection timed out: \(phase)"
        case .noVideoData:
            return "No video data received"
        }
    }
}

final class P4PClient {
    enum State: Int, Comparable {
        case idle, querying, wakingRelay, streamRequested, knocking, connected

        static func < (lhs: State, rhs: State) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let uid: String
    let password: String
    let username: String
    let streamType: UInt8

    private(set) var state: State = .idle
    private let socket: UDPSocket

    private var relayServers: [Endpoint] = []
    private var relayEndpoint: Endpoint?
    private var sessionToken: UInt32 = 0
    private var kcpConv: UInt32 = 0

    private var kcpRecvBuf: [UInt32: Data] = [:]
    private var kcpNextSN: UInt32 = 0
    private var kcpUNA: UInt32 = 0
    private var running = false

    private var videoFile: FileHandle?
    private var rawDumpFile: FileHandle?
    private var bytesWritten = 0
    private var rdtParser: RDTParser?
    private var videoCallback: ((Data, AVFrame) -> Void)?
    private(set) var reportedFramerate: UInt8 = 0
    private var seenIFrame = false
    private var captureStart: Date?

    private var wakeupResponsesReceived = 0

    private static var resolvedMasters: [Endpoint] = []

    init(
        uid: String, password: String,
        username: String = "admin",
        streamType: UInt8 = P4P.streamMain
    ) throws {
        self.uid = uid
        self.password = password
        self.username = username
        self.streamType = streamType
        self.socket = try UDPSocket()
        Log.info("Bound UDP socket on port \(socket.localPort)")
    }

    // MARK: - Public API

    /// Run the full connection handshake. Returns `true` on success.
    func connect(timeout: TimeInterval = 30.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        Log.info("Phase 1: Querying master servers for relay info...")
        state = .querying
        let queryPkt = P4P.buildQueryRequest(uid: uid)
        let masters = Self.resolveMasters()
        guard !masters.isEmpty else {
            Log.error("No master servers resolved")
            return false
        }

        for master in masters {
            socket.send(queryPkt, to: master)
            Log.debug("  Sent query to \(master)")
        }

        guard waitForState(.wakingRelay, deadline: deadline) else {
            Log.error("Timed out waiting for query response")
            return false
        }

        Log.info("Phase 2: Sending relay wakeup to \(relayServers.count) servers...")
        let wakeupPkt = P4P.buildRelayWakeupRequest(uid: uid)
        let wakeupStart = Date()

        while state == .wakingRelay && Date() < deadline {
            for srv in relayServers {
                socket.send(wakeupPkt, to: srv)
            }
            let retryDeadline = min(
                Date().addingTimeInterval(0.5), deadline
            )
            if waitForState(.streamRequested, deadline: retryDeadline) {
                break
            }
            let elapsed = Date().timeIntervalSince(wakeupStart)
            if elapsed > 15 {
                Log.warning(String(
                    format: "Relay wakeup taking %.1fs, still trying...",
                    elapsed
                ))
            }
        }

        guard state == .streamRequested else {
            Log.error("Timed out waiting for relay wakeup response")
            return false
        }

        Log.info("Phase 3: Sending relay stream request...")
        let randomID = UInt32.random(in: 0...UInt32.max)
        let streamPkt = P4P.buildRelayStreamRequest(
            uid: uid, password: password, username: username,
            localPort: socket.localPort, randomID: randomID,
            streamType: streamType
        )
        var attempts = 0

        while state == .streamRequested && Date() < deadline {
            for srv in relayServers {
                socket.send(streamPkt, to: srv)
            }
            attempts += 1
            let retryDeadline = min(
                Date().addingTimeInterval(1.0), deadline
            )
            if waitForState(.knocking, deadline: retryDeadline) {
                break
            }
            if attempts > 16 {
                Log.error("Too many stream request retries")
                return false
            }
        }

        guard state == .knocking, let endpoint = relayEndpoint else {
            Log.error("Timed out waiting for relay stream response")
            return false
        }

        Log.info("Phase 4: Sending knock to relay \(endpoint)")
        let knockPkt = P4P.buildKnock(
            uid: uid, password: password, username: username,
            sessionToken: sessionToken, kcpConv: kcpConv
        )
        socket.send(knockPkt, to: endpoint)

        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.2)
            socket.send(knockPkt, to: endpoint)
            recvAndDispatch(timeout: 0.3)
        }

        state = .connected
        Log.info("Connected! Relay endpoint: \(endpoint)")
        return true
    }

    /// Send AV control command to start video streaming.
    func startVideo(channel: UInt8 = 0) {
        guard let endpoint = relayEndpoint else {
            Log.error("Not connected, cannot start video")
            return
        }
        let avPkt = P4P.buildAVStartVideo(
            channel: channel, streamType: streamType
        )
        socket.send(avPkt, to: endpoint)
        let quality: String = {
            switch streamType {
            case P4P.streamMain:   return "HD"
            case P4P.streamSub:    return "SD"
            case P4P.streamLFMain: return "LF-HD"
            case P4P.streamLFSub:  return "LF-SD"
            default:               return "?"
            }
        }()
        Log.info("Sent start video command (channel \(channel), \(quality))")
    }

    /// Main receive loop — collects video data and writes clean H.265.
    func recvLoop(
        outputFile: String = "output.h265",
        rawDump: String? = nil,
        duration: TimeInterval = 30.0
    ) {
        running = true
        bytesWritten = 0

        FileManager.default.createFile(atPath: outputFile, contents: nil)
        videoFile = FileHandle(forWritingAtPath: outputFile)

        rdtParser = RDTParser(onVideo: { [weak self] data, frame in
            self?.onVideoFrame(data, frame)
        })

        if let rawDump {
            FileManager.default.createFile(atPath: rawDump, contents: nil)
            rawDumpFile = FileHandle(forWritingAtPath: rawDump)
        }

        captureStart = nil
        let start = Date()
        let keepaliveInterval: TimeInterval = 5.0
        var lastKeepalive = Date()
        var lastStatus = Date()

        Log.info("Receiving video for \(Int(duration))s, writing to \(outputFile)")

        while running {
            let elapsed = Date().timeIntervalSince(captureStart ?? start)
            guard elapsed < duration else { break }

            recvAndDispatch(timeout: 0.1)

            let now = Date()
            if now.timeIntervalSince(lastKeepalive) > keepaliveInterval {
                let alivePkt = P4P.buildAlive(
                    sessionToken: sessionToken, conv: kcpConv
                )
                if let endpoint = relayEndpoint {
                    socket.send(alivePkt, to: endpoint)
                }
                lastKeepalive = now
            }

            if now.timeIntervalSince(lastStatus) > 5.0 {
                let total = now.timeIntervalSince(start)
                let vf = rdtParser?.videoFrames ?? 0
                let af = rdtParser?.audioFrames ?? 0
                Log.info(String(
                    format: "  %.0fs elapsed, %d bytes H.265, "
                    + "%d video frames, %d audio frames, "
                    + "KCP sn=%d",
                    total, bytesWritten, vf, af, kcpNextSN
                ))
                lastStatus = now
            }
        }

        running = false
        videoFile?.closeFile()
        videoFile = nil
        rawDumpFile?.closeFile()
        rawDumpFile = nil

        let vf = rdtParser?.videoFrames ?? 0
        Log.info("Done. \(vf) video frames, \(bytesWritten) bytes written to \(outputFile)")
    }

    func close() {
        running = false
        videoFile?.closeFile()
        videoFile = nil
        rawDumpFile?.closeFile()
        rawDumpFile = nil
        socket.close()
    }

    // MARK: - DNS resolution

    private static func resolveMasters() -> [Endpoint] {
        if !resolvedMasters.isEmpty { return resolvedMasters }

        var resolved: [Endpoint] = []
        for (host, port) in P4P.masterServers {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM

            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0,
                  let info = result else {
                Log.warning("Failed to resolve \(host)")
                continue
            }
            defer { freeaddrinfo(result) }

            guard let ai_addr = info.pointee.ai_addr else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            ai_addr.withMemoryRebound(
                to: sockaddr_in.self, capacity: 1
            ) { ptr in
                var sinAddr = ptr.pointee.sin_addr
                inet_ntop(
                    AF_INET, &sinAddr, &hostBuf,
                    socklen_t(INET_ADDRSTRLEN)
                )
            }
            let ip = String(cString: hostBuf)
            resolved.append(Endpoint(host: ip, port: port))
            Log.info("Resolved \(host) -> \(ip)")
        }

        resolvedMasters = resolved
        return resolved
    }

    // MARK: - Video frame handling

    /// Called by the RDT parser for each video frame.
    private func onVideoFrame(_ data: Data, _ frame: AVFrame) {
        if reportedFramerate == 0 && frame.framerate != 0 {
            reportedFramerate = frame.framerate
            Log.info("Camera reports framerate: \(frame.framerate) fps")
        }
        if !seenIFrame {
            guard frame.isIFrame else { return }
            seenIFrame = true
            captureStart = Date()
            Log.info("First I-frame received, starting capture")
        }
        videoFile?.write(data)
        bytesWritten += data.count
        videoCallback?(data, frame)
    }

    // MARK: - State machine

    @discardableResult
    private func waitForState(
        _ target: State, deadline: Date
    ) -> Bool {
        while state < target && Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            recvAndDispatch(timeout: min(remaining, 0.5))
        }
        return state >= target
    }

    private func recvAndDispatch(timeout: TimeInterval = 0.5) {
        guard socket.waitForData(timeout: timeout) else { return }
        while let (data, endpoint) = socket.receive() {
            guard data.count >= 4 else { continue }
            handlePacket(data, from: endpoint)
        }
    }

    private func handlePacket(_ data: Data, from addr: Endpoint) {
        let dec = P4P.decryptPacket(data)
        let magic = P4P.packetMagic(dec)
        guard magic == P4P.magic else {
            Log.debug(String(
                format: "Non-P4P packet from %@ (magic=0x%04x, %d bytes)",
                addr.description, magic, dec.count
            ))
            return
        }

        let cmd = P4P.packetCmd(dec)

        switch cmd {
        case P4P.cmdQueryRsp:
            handleQueryResponse(dec)
        case P4P.cmdRlyWakeupRsp:
            handleWakeupResponse(dec)
        case P4P.cmdRlyStreamRsp:
            handleStreamResponse(dec, from: addr)
        case P4P.cmdAlive:
            Log.debug("Keepalive from \(addr)")
        case P4P.cmdKCPData:
            handleKCPData(dec, from: addr)
        case P4P.cmdKnock:
            Log.debug("Knock response from \(addr)")
        default:
            Log.debug(String(
                format: "Unknown cmd 0x%04x from %@ (%d bytes)",
                cmd, addr.description, dec.count
            ))
        }
    }

    // MARK: - Response handlers

    private func handleQueryResponse(_ dec: Data) {
        guard state == .querying else { return }

        let response = P4P.parseQueryResponse(dec)
            ?? parseQueryDirect(dec)

        guard let result = response,
              !result.relayServers.isEmpty else { return }

        relayServers = result.relayServers.filter { $0.host != "0.0.0.0" }
        Log.info("Got \(relayServers.count) relay servers from query response")
        for server in relayServers {
            Log.info("  Relay: \(server)")
        }
        state = .wakingRelay
    }

    private func parseQueryDirect(_ dec: Data) -> P4P.QueryResponse? {
        guard dec.count >= 88 else { return nil }
        let uid = dec.asciiString(at: 20, maxLength: 20)
        var relayServers: [Endpoint] = []
        for i in 0..<4 {
            let offset = 72 + i * 4
            guard offset + 4 <= dec.count else { break }
            let ip = dec.ipString(at: offset)
            if ip != "0.0.0.0" {
                relayServers.append(Endpoint(host: ip, port: 20001))
            }
        }
        return P4P.QueryResponse(
            uid: uid, relayServers: relayServers,
            vpgID: Data(), raw: dec
        )
    }

    private func handleWakeupResponse(_ dec: Data) {
        guard state == .wakingRelay else { return }
        let status: UInt8 = dec.count > 16 ? dec[dec.startIndex + 16] : 0
        wakeupResponsesReceived += 1
        Log.debug(String(
            format: "Relay wakeup response #%d, status=0x%02x",
            wakeupResponsesReceived, status
        ))
        if status >= 0x01 && wakeupResponsesReceived >= 2 {
            Log.info(
                "Relay wakeup accepted after \(wakeupResponsesReceived) responses"
            )
            state = .streamRequested
        }
    }

    private func handleStreamResponse(
        _ dec: Data, from addr: Endpoint
    ) {
        guard state == .streamRequested else { return }

        guard let result = P4P.parseRelayStreamResponse(dec) else {
            Log.warning("Could not parse relay stream response")
            return
        }

        if !result.relayIP.isEmpty
            && result.relayIP != "0.0.0.0"
            && result.relayPort > 0
        {
            relayEndpoint = Endpoint(
                host: result.relayIP, port: result.relayPort
            )
            sessionToken = result.sessionToken
            kcpConv = result.kcpConv
            state = .knocking
            Log.info(String(
                format: "Relay stream response: endpoint %@:%d, "
                + "session=0x%08x, conv=0x%08x",
                result.relayIP, result.relayPort,
                sessionToken, kcpConv
            ))
        } else {
            Log.warning(
                "Could not extract relay endpoint, using sender \(addr)"
            )
            relayEndpoint = addr
            state = .knocking
        }
    }

    // MARK: - KCP handling

    private func handleKCPData(_ dec: Data, from addr: Endpoint) {
        let kcpData = Data(dec.dropFirst(16))
        var offset = 0
        var pendingAcks: [Data] = []

        while offset < kcpData.count {
            guard let seg = P4P.parseKCPSegment(kcpData, at: offset) else {
                break
            }

            if kcpConv == 0 {
                kcpConv = seg.conv
                Log.info(String(
                    format: "KCP conversation ID: 0x%08x", kcpConv
                ))
            }

            if seg.cmd == P4P.kcpCmdPush {
                let dataEnd = seg.dataOffset + Int(seg.len)
                guard dataEnd <= kcpData.count else {
                    Log.warning(
                        "KCP segment data truncated: "
                        + "need \(dataEnd) have \(kcpData.count)"
                    )
                    break
                }

                let payload = Data(
                    kcpData[seg.dataOffset..<dataEnd]
                )
                processKCPPayload(sn: seg.sn, frg: seg.frg, data: payload)

                pendingAcks.append(
                    P4P.buildKCPAck(
                        conv: seg.conv, sn: seg.sn,
                        ts: seg.ts, una: kcpUNA
                    )
                )
                offset = dataEnd
            } else {
                offset += P4P.kcpHeaderSize
            }
        }

        if !pendingAcks.isEmpty, let endpoint = relayEndpoint {
            sendBatchedAcks(pendingAcks, to: endpoint)
        }
    }

    private func sendBatchedAcks(
        _ acks: [Data], to endpoint: Endpoint
    ) {
        var totalKCP = Data()
        for ack in acks { totalKCP.append(ack) }

        var pkt = Data(count: 16)
        pkt.writeUInt16LE(P4P.magic, at: 0)
        pkt.writeUInt16LE(P4P.version, at: 2)
        pkt.writeUInt16LE(UInt16(totalKCP.count), at: 4)
        pkt.writeUInt16LE(P4P.cmdKCPAck, at: 8)
        pkt.writeUInt16LE(0x21, at: 10)
        pkt.append(totalKCP)

        let encrypted = Crypto.encode(pkt)
        socket.send(encrypted, to: endpoint)
    }

    private func processKCPPayload(
        sn: UInt32, frg: UInt8, data: Data
    ) {
        kcpRecvBuf[sn] = data
        kcpUNA = max(kcpUNA, sn + 1)

        while let chunk = kcpRecvBuf.removeValue(forKey: kcpNextSN) {
            kcpNextSN += 1
            deliverData(chunk)
        }
    }

    private func deliverData(_ data: Data) {
        rawDumpFile?.write(data)
        rdtParser?.feed(data)
    }
}
