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

public final class P4PClient {
    public enum State: Int, Comparable {
        case idle, querying, wakingRelay, streamRequested, knocking, connected

        public static func < (lhs: State, rhs: State) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let uid: String
    public let password: String
    public let username: String
    public let streamType: UInt8

    public private(set) var state: State = .idle
    private var socket: UDPSocket

    private var relayServers: [Endpoint] = []
    // Control-plane endpoint: from the relay stream response body. Used for
    // the alive that registers the session and for periodic keepalives.
    private var relayEndpoint: Endpoint?
    // Data-plane endpoint: source address of the camera's KCP pushes. The
    // relay forwards data from a different host than the one it advertises.
    // ACKs only reach the camera if mirrored to this address.
    private var dataEndpoint: Endpoint?
    private var sessionToken: UInt32 = 0
    private var kcpConv: UInt32 = 0

    private var kcpRecvBuf: [UInt32: Data] = [:]
    private var kcpNextSN: UInt32 = 0
    private var kcpUNA: UInt32 = 0
    private var kcpLastAdvance: Date = Date()
    private var running = false
    private var streamingStopped: DispatchSemaphore?

    private var videoFile: FileHandle?
    private var rawDumpFile: FileHandle?
    private var bytesWritten = 0
    private var rdtParser: RDTParser?
    private var videoCallback: ((Data, AVFrame) -> Void)?
    public private(set) var reportedFramerate: UInt8 = 0
    public private(set) var bytesReceived: Int = 0
    private var seenIFrame = false
    private var captureStart: Date?

    private var wakeupResponsesReceived = 0
    private var keepalivesReceived = 0
    private var keepalivesSent = 0
    private var lastDataReceived: Date?
    private var streamingQueue: DispatchQueue?

    private static var resolvedMasters: [Endpoint] = []

    public init(
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
    public func connect(timeout: TimeInterval = 30.0) -> Bool {
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

        // Mobile app capture shows: after the relay stream response, the
        // client sends a single alive packet to bind its UDP endpoint to the
        // session, and the camera then begins KCP streaming. No knock packet
        // is sent in relay mode. Sending the wrong handshake here puts the
        // camera in a state where it streams data but ignores our ACKs, so
        // its send window fills at ~256 packets and the stream stalls.
        Log.info("Phase 4: Sending alive to bind endpoint \(endpoint)")
        let alivePkt = P4P.buildAlive(
            sessionToken: sessionToken, conv: kcpConv
        )
        socket.send(alivePkt, to: endpoint)

        state = .connected
        Log.info("Connected! Relay endpoint: \(endpoint), conv=0x\(String(kcpConv, radix: 16))")
        return true
    }

    /// Send AV control command to start video streaming.
    public func startVideo(channel: UInt8 = 0) {
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

    /// Send AV control command to stop video streaming.
    public func stopVideo(channel: UInt8 = 0) {
        guard let endpoint = relayEndpoint else { return }
        let pkt = P4P.buildAVStopVideo(
            channel: channel, streamType: streamType
        )
        socket.send(pkt, to: endpoint)
        Log.info("Sent stop video command")
    }

    /// Main receive loop — collects video data and writes clean H.265.
    public func recvLoop(
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

    public func close() {
        running = false

        // Wait for the streaming loop to exit so it stops using the socket.
        if let semaphore = streamingStopped {
            _ = semaphore.wait(timeout: .now() + 2.0)
            streamingStopped = nil
        }

        // Tell the relay to stop sending video and close the session.
        stopVideo()
        if let endpoint = relayEndpoint {
            let logout = P4P.buildRelayLogout()
            socket.send(logout, to: endpoint)
            // Send logout multiple times to improve delivery reliability (UDP).
            socket.send(logout, to: endpoint)
            socket.send(logout, to: endpoint)
            Log.info("Sent relay logout request")
        }

        videoFile?.closeFile()
        videoFile = nil
        rawDumpFile?.closeFile()
        rawDumpFile = nil
        socket.close()
    }

    /// Reset connection state and re-establish the relay session.
    /// Returns true if reconnection succeeded.
    private func reconnect() -> Bool {
        Log.info("Reconnecting...")
        socket.close()

        guard let newSocket = try? UDPSocket() else {
            Log.error("Failed to create new socket for reconnect")
            return false
        }
        socket = newSocket

        state = .idle
        relayServers = []
        relayEndpoint = nil
        dataEndpoint = nil
        sessionToken = 0
        kcpConv = 0
        kcpRecvBuf.removeAll()
        kcpNextSN = 0
        kcpUNA = 0
        kcpLastAdvance = Date()
        wakeupResponsesReceived = 0
        seenIFrame = false
        rdtParser?.reset()

        guard connect(timeout: 30.0) else {
            Log.error("Reconnection failed")
            return false
        }
        lastDataReceived = Date()
        keepalivesReceived = 0
        keepalivesSent = 0
        Log.info("Reconnected successfully")
        return true
    }

    /// Start streaming video on a background thread, delivering H.265 data via callback.
    public func startStreaming(onFrame: @escaping (Data, AVFrame) -> Void) {
        running = true
        seenIFrame = false
        videoCallback = onFrame

        // Reset KCP state — we ignored KCP data during the knock phase, so
        // the relay's KCP starts fresh from sn=0 for actual video data.
        Log.info("startStreaming: resetting KCP state (nextSN=\(kcpNextSN), una=\(kcpUNA), buf=\(kcpRecvBuf.count))")
        kcpRecvBuf.removeAll()
        kcpNextSN = 0
        kcpUNA = 0
        kcpLastAdvance = Date()
        kcpPushCount = 0
        kcpRetransmitCount = 0
        kcpNonPushCount = 0
        kcpConvMismatchCount = 0
        nonP4PCount = 0
        unknownCmdCount = 0
        acksSent = 0
        knockPingCount = 0

        rdtParser = RDTParser(onVideo: { [weak self] data, frame in
            self?.onVideoFrame(data, frame)
        })

        let semaphore = DispatchSemaphore(value: 0)
        streamingStopped = semaphore

        let queue = DispatchQueue(label: "com.ubox.stream", qos: .userInitiated)
        streamingQueue = queue

        queue.async { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            // Mobile app sends an alive between the relay stream response
            // and any KCP traffic — appears to bind our endpoint to the
            // session on the camera side. Without it, the camera keeps
            // sending data but ignores our ACKs.
            if let endpoint = self.relayEndpoint {
                let alivePkt = P4P.buildAlive(
                    sessionToken: self.sessionToken, conv: self.kcpConv
                )
                self.socket.send(alivePkt, to: endpoint)
            }
            var lastKeepalive = Date()
            var lastStatus = Date()
            let start = Date()
            self.lastDataReceived = start
            self.keepalivesReceived = 0
            self.keepalivesSent = 0

            Log.info("Streaming started")

            while self.running {
                self.recvAndDispatch(timeout: 0.05)

                let now = Date()
                if now.timeIntervalSince(lastKeepalive) > 5.0 {
                    let alivePkt = P4P.buildAlive(
                        sessionToken: self.sessionToken, conv: self.kcpConv
                    )
                    if let endpoint = self.relayEndpoint {
                        self.socket.send(alivePkt, to: endpoint)
                    }
                    self.keepalivesSent += 1
                    lastKeepalive = now
                }

                let sinceData = self.lastDataReceived.map {
                    now.timeIntervalSince($0)
                } ?? now.timeIntervalSince(start)

                // Auto-reconnect when relay goes silent.
                if sinceData > 15.0 {
                    Log.warning(String(
                        format: "No data for %.0fs — attempting reconnect",
                        sinceData
                    ))
                    if self.reconnect() {
                        lastKeepalive = Date()
                        lastStatus = Date()
                    } else {
                        Log.error("Reconnect failed, stopping stream")
                        self.running = false
                    }
                    continue
                }


                // Periodic stall check — runs even when no PUSH data arrives
                if !self.kcpRecvBuf.isEmpty {
                    let stallTime = now.timeIntervalSince(self.kcpLastAdvance)
                    if stallTime > 2.0 {
                        Log.info("KCP loop stall check: stallTime=\(String(format: "%.1f", stallTime))s, buf=\(self.kcpRecvBuf.count), nextSN=\(self.kcpNextSN)")
                        self.skipKCPGap()
                    }
                }

                let elapsed = now.timeIntervalSince(start)
                let statusInterval: TimeInterval = elapsed < 15 ? 1.0 : 5.0
                if now.timeIntervalSince(lastStatus) > statusInterval {
                    let vf = self.rdtParser?.videoFrames ?? 0
                    let af = self.rdtParser?.audioFrames ?? 0
                    let bufCount = self.kcpRecvBuf.count
                    Log.info(String(
                        format: "  %.0fs elapsed, %d bytes recv, %d pkts, "
                        + "%d video frames, %d audio frames, "
                        + "KCP sn=%d, buf=%d, push=%d, retransmit=%d, "
                        + "keepalive %d/%d, acks=%d, "
                        + "last data %.1fs ago, "
                        + "I-frame=%@, "
                        + "nonPush=%d, convMismatch=%d, "
                        + "nonP4P=%d, unknownCmd=%d, knockPing=%d",
                        elapsed, self.bytesReceived, self.packetsReceived,
                        vf, af,
                        self.kcpNextSN, bufCount,
                        self.kcpPushCount, self.kcpRetransmitCount,
                        self.keepalivesReceived, self.keepalivesSent,
                        self.acksSent,
                        sinceData,
                        self.seenIFrame ? "yes" : "no",
                        self.kcpNonPushCount, self.kcpConvMismatchCount,
                        self.nonP4PCount, self.unknownCmdCount,
                        self.knockPingCount
                    ))
                    if bufCount > 50 {
                        Log.warning("KCP reorder buffer has \(bufCount) pending packets — possible sequence gap at sn=\(self.kcpNextSN)")
                    }
                    lastStatus = now
                }
            }

            Log.info("Streaming stopped")
        }
    }

    /// Stop the background streaming loop and wait for it to finish.
    public func stopStreaming() {
        running = false
        if let semaphore = streamingStopped {
            _ = semaphore.wait(timeout: .now() + 2.0)
            streamingStopped = nil
        }
        videoCallback = nil
        rdtParser = nil
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
            if frame.isIFrame {
                seenIFrame = true
                captureStart = Date()
                Log.info("First I-frame received (\(data.count) bytes), starting capture")
            } else {
                Log.debug("Skipping non-I-frame (\(data.count) bytes) before first I-frame")
                return
            }
        }
        videoFile?.write(data)
        bytesWritten += data.count
        Log.debug("Video frame delivered: \(frame.isIFrame ? "I" : "P")-frame, \(data.count) bytes")
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

    private var packetsReceived: Int = 0

    private func recvAndDispatch(timeout: TimeInterval = 0.5) {
        guard socket.waitForData(timeout: timeout) else { return }
        while let (data, endpoint) = socket.receive() {
            guard data.count >= 4 else { continue }
            bytesReceived += data.count
            packetsReceived += 1
            handlePacket(data, from: endpoint)
        }
    }

    private func handlePacket(_ data: Data, from addr: Endpoint) {
        let dec = P4P.decryptPacket(data)
        let magic = P4P.packetMagic(dec)
        guard magic == P4P.magic else {
            nonP4PCount += 1
            if nonP4PCount <= 5 {
                Log.info(String(
                    format: "Non-P4P packet from %@ (magic=0x%04x, %d bytes)",
                    addr.description, magic, dec.count
                ))
            }
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
        case P4P.cmdAliveRsp:
            keepalivesReceived += 1
            Log.debug("Keepalive from \(addr)")
        case P4P.cmdKCPData:
            // Only process KCP data once streaming is active. Data arriving
            // during the knock phase is residual relay traffic that corrupts
            // the KCP window state if acknowledged.
            if running {
                handleKCPData(dec, from: addr)
            } else {
                lastDataReceived = Date()
            }
        case P4P.cmdKnock:
            Log.debug("Knock response from \(addr)")
        case P4P.cmdKnockRelayR:
            Log.debug("Knock relay response from \(addr)")
        case P4P.cmdKnockPing:
            knockPingCount += 1
            Log.debug("Knock ping from \(addr), responding")
            let knockPkt = P4P.buildKnock(
                uid: uid, password: password, username: username,
                sessionToken: sessionToken, kcpConv: kcpConv
            )
            socket.send(knockPkt, to: addr)
        default:
            unknownCmdCount += 1
            if unknownCmdCount <= 10 {
                Log.info(String(
                    format: "Unknown cmd 0x%04x from %@ (%d bytes)",
                    cmd, addr.description, dec.count
                ))
            }
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

        // The body's relayIP is the "control plane" relay address — used for
        // the alive (which registers our session). Data flows back from a
        // different "data plane" relay, and we'll switch acks to that
        // address when the first KCP push arrives. Both paths must be hit:
        // body-IP gets the session bound, data-source-IP gets acks to the
        // camera's KCP state.
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
                format: "Relay stream response from %@: control endpoint %@:%d, "
                + "session=0x%08x, conv=0x%08x",
                addr.description, result.relayIP, result.relayPort,
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

    private var kcpNonPushCount = 0
    private var kcpConvMismatchCount = 0
    private var kcpRetransmitCount = 0
    private var kcpPushCount = 0
    private var nonP4PCount = 0
    private var unknownCmdCount = 0
    private var acksSent = 0
    private var knockPingCount = 0

    private func handleKCPData(_ dec: Data, from addr: Endpoint) {
        lastDataReceived = Date()
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

            if seg.conv != kcpConv {
                kcpConvMismatchCount += 1
                if kcpConvMismatchCount <= 5 {
                    Log.warning(String(
                        format: "KCP conv mismatch: got 0x%08x expected 0x%08x, sn=%d cmd=%d",
                        seg.conv, kcpConv, seg.sn, seg.cmd
                    ))
                }
                offset += (seg.cmd == P4P.kcpCmdPush)
                    ? seg.dataOffset + Int(seg.len)
                    : P4P.kcpHeaderSize
                continue
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
                kcpNonPushCount += 1
                if kcpNonPushCount <= 10 {
                    Log.info(String(
                        format: "KCP non-PUSH cmd=%d sn=%d una=%d wnd=%d",
                        seg.cmd, seg.sn, seg.una, seg.wnd
                    ))
                }
                offset += P4P.kcpHeaderSize
            }
        }

        if !pendingAcks.isEmpty {
            if dataEndpoint != addr {
                Log.info("Data-plane endpoint: \(addr) (control plane is \(relayEndpoint?.description ?? "nil"))")
                dataEndpoint = addr
                // Re-send the alive to the data-plane address so the camera
                // binds our session there too. The response body's IP is a
                // hole-punched/P2P address which often differs from where the
                // relay actually streams data; without rebinding to the data
                // path, the camera ignores our ACKs and snd_una stays at 0,
                // freezing at sn=256 (the initial cwnd burst).
                let alivePkt = P4P.buildAlive(
                    sessionToken: sessionToken, conv: kcpConv
                )
                socket.send(alivePkt, to: addr)
                // Also keep relayEndpoint in sync so keepalives use the path
                // we know is reaching the camera.
                relayEndpoint = addr
            }
            sendBatchedAcks(pendingAcks, to: addr)
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
        pkt.writeUInt16LE(P4P.subRelay, at: 10)
        pkt.writeUInt16LE(UInt16(sessionToken >> 16), at: 12)
        pkt.append(totalKCP)

        let encrypted = Crypto.encode(pkt)
        socket.send(encrypted, to: endpoint)
        acksSent += acks.count
    }

    private var lastProcessLog = Date.distantPast

    private func processKCPPayload(
        sn: UInt32, frg: UInt8, data: Data
    ) {
        kcpPushCount += 1
        // Drop packets we've already delivered — don't let them accumulate.
        if sn < kcpNextSN {
            kcpRetransmitCount += 1
            if kcpRetransmitCount <= 5 {
                Log.info("KCP retransmit dropped: sn=\(sn) < nextSN=\(kcpNextSN), una=\(kcpUNA)")
            }
            return
        }

        kcpRecvBuf[sn] = data

        let delivered = drainKCPBuffer()
        kcpUNA = kcpNextSN

        // If nothing was delivered and the buffer is stuck, skip the gap.
        if !delivered && !kcpRecvBuf.isEmpty {
            let now = Date()
            let stallTime = now.timeIntervalSince(kcpLastAdvance)
            if stallTime > 2.0 {
                Log.info("KCP stall recovery: stallTime=\(String(format: "%.1f", stallTime))s, buf=\(kcpRecvBuf.count), nextSN=\(kcpNextSN)")
                skipKCPGap()
            }
        }
    }

    /// Deliver contiguous packets starting from kcpNextSN.
    /// Returns true if at least one packet was delivered.
    @discardableResult
    private func drainKCPBuffer() -> Bool {
        var any = false
        while let chunk = kcpRecvBuf.removeValue(forKey: kcpNextSN) {
            kcpNextSN += 1
            deliverData(chunk)
            any = true
        }
        if any { kcpLastAdvance = Date() }
        return any
    }

    /// Skip missing KCP sequence numbers and resume delivery.
    private func skipKCPGap() {
        let beforeCount = kcpRecvBuf.count
        // Purge any stale packets with SN below kcpNextSN.
        let staleKeys = kcpRecvBuf.keys.filter { $0 < kcpNextSN }
        for key in staleKeys {
            kcpRecvBuf.removeValue(forKey: key)
        }
        if !staleKeys.isEmpty {
            Log.info("KCP skipGap: purged \(staleKeys.count) stale packets (below sn=\(kcpNextSN)), buf \(beforeCount) -> \(kcpRecvBuf.count)")
        }
        guard let minSN = kcpRecvBuf.keys.min(),
              minSN > kcpNextSN else {
            Log.warning("KCP skipGap: no packets ahead of sn=\(kcpNextSN), buf=\(kcpRecvBuf.count) — cannot skip")
            return
        }
        let skipped = minSN - kcpNextSN
        Log.warning("KCP stall: skipping \(skipped) missing packet(s) (sn \(kcpNextSN)..<\(minSN)), buf=\(kcpRecvBuf.count)")
        kcpNextSN = minSN
        rdtParser?.reset()
        let drained = drainKCPBuffer()
        Log.info("KCP skipGap: after drain nextSN=\(kcpNextSN), buf=\(kcpRecvBuf.count), drained=\(drained)")
    }

    private func deliverData(_ data: Data) {
        rawDumpFile?.write(data)
        rdtParser?.feed(data)
    }
}
