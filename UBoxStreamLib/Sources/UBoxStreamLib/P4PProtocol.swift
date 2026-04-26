/// UBIA P4P protocol constants, packet builders, and parsers.
///
/// Packet header (16 bytes, little-endian):
///   magic(2) + version(2) + payload_len(2) + reserved(2)
///   + cmd(2) + sub(2) + flags(4)
import Foundation
import Darwin

// MARK: - Endpoint

public struct Endpoint: Equatable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { "\(host):\(port)" }
}

// MARK: - Constants

public enum P4P {
    public static let magic: UInt16   = 0x1807
    public static let version: UInt16 = 0x0010

    static let cmdQueryReq: UInt16     = 0x1051
    static let cmdQueryRsp: UInt16     = 0x1052
    static let cmdRlyWakeupReq: UInt16 = 0x1201
    static let cmdRlyWakeupRsp: UInt16 = 0x1202
    static let cmdRlyStreamReq: UInt16 = 0x1205
    static let cmdRlyStreamRsp: UInt16 = 0x1206
    static let cmdLanSearchReq: UInt16 = 0x1301
    static let cmdLanSearchRsp: UInt16 = 0x1304
    static let cmdKnock: UInt16        = 0x1403
    static let cmdKnockRelay: UInt16   = 0x130b
    static let cmdKnockRelayR: UInt16  = 0x130c
    static let cmdKnockPing: UInt16    = 0x130e
    // Outbound (client→camera). Camera's receiver dispatches 0x1405 to
    // p4p_device_handle_alive; 0x1406 is the camera's reply cmd. The relay
    // routes by cmd, so 0x1406 outbound never reaches the camera's alive
    // handler and the session never registers as alive.
    static let cmdAlive: UInt16        = 0x1405
    static let cmdAliveRsp: UInt16     = 0x1406
    static let cmdAVCtrl: UInt16       = 0x1407
    static let cmdKCPAck: UInt16       = 0x1409
    static let cmdKCPData: UInt16      = 0x140a

    static let cmdRlyLogoutReq: UInt16 = 0x1207
    static let avCmdStopVideo: UInt8  = 0x02
    static let avCmdStartVideo: UInt8 = 0x09

    static let subQuery: UInt16 = 0x28
    static let subRelay: UInt16 = 0x24
    static let subKnock: UInt16 = 0x21
    static let subAlive: UInt16 = 0x12

    public static let streamSub: UInt8    = 0   // SD — camera's sub stream (lower resolution)
    public static let streamMain: UInt8   = 1   // HD — camera's main stream (full resolution)
    public static let streamLFSub: UInt8  = 2   // Low-framerate SD (used for multi-cam grid views)
    public static let streamLFMain: UInt8 = 3   // Low-framerate HD

    static let codecVideoMPEG4: UInt16 = 76
    static let codecVideoH263: UInt16  = 77
    static let codecVideoH264: UInt16  = 78
    static let codecVideoMJPEG: UInt16 = 79
    static let codecVideoH265: UInt16  = 80
    static let codecAudioADPCM: UInt16 = 139
    static let codecAudioPCM: UInt16   = 140
    static let codecAudioSpeex: UInt16 = 141
    static let codecAudioMP3: UInt16   = 142
    static let codecAudioG726: UInt16  = 143

    static let rdtVideo: UInt8 = 0x11
    static let rdtAudio: UInt8 = 0x13

    static let rdtHeaderSize   = 16
    static let avframeWireSize = 16

    static let kcpHeaderSize = 24
    static let kcpCmdPush: UInt8 = 81
    static let kcpCmdAck: UInt8  = 82
    static let kcpCmdWAsk: UInt8 = 83
    static let kcpCmdWIns: UInt8 = 84

    static let masterServers: [(host: String, port: UInt16)] = [
        ("m1.ubianet.com", 10240),
        ("m2.ubianet.com", 10240),
        ("m3.ubianet.com", 10240),
        ("m4.ubianet.com", 10240),
        ("m5.ubianet.com", 10240),
        ("m6.ubianet.com", 10240),
    ]
}

// MARK: - Response types

extension P4P {
    struct QueryResponse {
        let uid: String
        let relayServers: [Endpoint]
        let vpgID: Data
        let raw: Data
    }

    struct StreamResponse {
        let relayIP: String
        let relayPort: UInt16
        let sessionToken: UInt32
        let kcpConv: UInt32
        let raw: Data
    }

    struct KCPSegment {
        let conv: UInt32
        let cmd: UInt8
        let frg: UInt8
        let wnd: UInt16
        let ts: UInt32
        let sn: UInt32
        let una: UInt32
        let len: UInt32
        let dataOffset: Int
    }
}

// MARK: - Packet builders

extension P4P {
    static let headerSize = 16

    private static func makePacket(
        size: Int, cmd: UInt16, sub: UInt16
    ) -> Data {
        var pkt = Data(count: size)
        pkt.writeUInt16LE(magic, at: 0)
        pkt.writeUInt16LE(version, at: 2)
        pkt.writeUInt16LE(UInt16(size - headerSize), at: 4)
        pkt.writeUInt16LE(cmd, at: 8)
        pkt.writeUInt16LE(sub, at: 10)
        return pkt
    }

    /// Build a 60-byte query request packet (encrypted).
    static func buildQueryRequest(uid: String) -> Data {
        var pkt = makePacket(size: 60, cmd: cmdQueryReq, sub: subQuery)
        pkt.writeASCII(uid, at: 20, maxLength: 20)
        return Crypto.encode(pkt)
    }

    /// Build a 60-byte relay wakeup request (encrypted).
    static func buildRelayWakeupRequest(uid: String) -> Data {
        var pkt = makePacket(size: 60, cmd: cmdRlyWakeupReq, sub: subRelay)
        pkt[16] = 0x01
        pkt[17] = 0x01
        pkt.writeASCII(uid, at: 20, maxLength: 20)
        return Crypto.encode(pkt)
    }

    /// Build a relay stream request (124 bytes, encrypted).
    ///
    /// Layout:
    ///   - `[0x00]` header (16 bytes)
    ///   - `[0x10]` flags (4 bytes)
    ///   - `[0x1c]` local IP (4 bytes, network order)
    ///   - `[0x20]` local port (2 bytes LE)
    ///   - `[0x28]` UID (20 bytes)
    ///   - `[0x3c]` password (16 bytes)
    ///   - `[0x58]` random_id (4 bytes LE)
    ///   - `[0x5c]` username (16 bytes)
    ///   - `[0x6c]` subcommand (4 bytes): 0x09 0x00 0x01 0x01
    static func buildRelayStreamRequest(
        uid: String, password: String, username: String = "admin",
        localIP: String = "0.0.0.0", localPort: UInt16 = 0,
        randomID: UInt32 = 0, streamType: UInt8 = streamMain
    ) -> Data {
        var pkt = makePacket(size: 124, cmd: cmdRlyStreamReq, sub: subRelay)
        pkt[16] = 0x01

        if localIP != "0.0.0.0" {
            pkt.writeIPv4(localIP, at: 0x1c)
        }
        pkt.writeUInt16LE(localPort, at: 0x20)
        pkt.writeASCII(uid, at: 0x28, maxLength: 20)
        pkt.writeASCII(password, at: 0x3c, maxLength: 16)
        if randomID != 0 {
            pkt.writeUInt32LE(randomID, at: 0x58)
        }
        pkt.writeASCII(username, at: 0x5c, maxLength: 16)
        pkt[0x6c] = avCmdStartVideo
        pkt[0x6e] = streamType
        pkt[0x6f] = 0x01

        return Crypto.encode(pkt)
    }

    /// Build a knock packet for the relay data endpoint (84 bytes).
    ///
    /// Layout:
    ///   - `[0x10]` UID (20 bytes)
    ///   - `[0x24]` password (16 bytes)
    ///   - `[0x3c]` session_token (4 bytes LE)
    ///   - `[0x40]` kcp_conv (4 bytes LE)
    ///   - `[0x44]` username (16 bytes)
    static func buildKnock(
        uid: String, password: String, username: String = "admin",
        sessionToken: UInt32 = 0, kcpConv: UInt32 = 0
    ) -> Data {
        var pkt = makePacket(size: 84, cmd: cmdKnockRelay, sub: subKnock)
        pkt.writeASCII(uid, at: 0x10, maxLength: 20)
        pkt.writeASCII(password, at: 0x24, maxLength: 16)
        pkt.writeUInt32LE(sessionToken, at: 0x3c)
        pkt.writeUInt32LE(kcpConv, at: 0x40)
        pkt.writeASCII(username, at: 0x44, maxLength: 16)
        return Crypto.encode(pkt)
    }

    /// Build a keepalive packet.
    static func buildAlive(
        sessionToken: UInt32 = 0, conv: UInt32 = 0
    ) -> Data {
        var pkt = makePacket(size: 36, cmd: cmdAlive, sub: subRelay)
        pkt.writeUInt16LE(UInt16(sessionToken >> 16), at: 12)
        // Body layout (matches mobile app capture):
        //   [16..20] zero
        //   [20..24] sessionToken (LE)
        //   [24..28] kcpConv (LE)
        pkt.writeUInt32LE(sessionToken, at: 20)
        pkt.writeUInt32LE(conv, at: 24)
        return Crypto.encode(pkt)
    }

    /// Build AV control command to start video streaming.
    ///
    /// Payload layout:
    ///   - byte 0: AV_CMD_START_VIDEO (0x09)
    ///   - byte 1: channel
    ///   - byte 2: stream_type (0=SD, 1=HD, 2=LF_SD, 3=LF_HD)
    ///   - byte 3: codec (1 = H.265)
    static func buildAVStartVideo(
        channel: UInt8 = 0, streamType: UInt8 = streamMain
    ) -> Data {
        var pkt = makePacket(size: 48, cmd: cmdAVCtrl, sub: 0)
        pkt[16] = avCmdStartVideo
        pkt[17] = channel
        pkt[18] = streamType
        pkt[19] = 0x01
        return Crypto.encode(pkt)
    }

    /// Build an AV control packet to stop video streaming.
    static func buildAVStopVideo(
        channel: UInt8 = 0, streamType: UInt8 = streamMain
    ) -> Data {
        var pkt = makePacket(size: 48, cmd: cmdAVCtrl, sub: 0)
        pkt[16] = avCmdStopVideo
        pkt[17] = channel
        pkt[18] = streamType
        pkt[19] = 0x01
        return Crypto.encode(pkt)
    }

    /// Build a relay logout request to cleanly close the session.
    static func buildRelayLogout() -> Data {
        let pkt = makePacket(size: 48, cmd: cmdRlyLogoutReq, sub: subRelay)
        return Crypto.encode(pkt)
    }
}

// MARK: - Packet parsers

extension P4P {
    /// Decrypt an incoming P4P packet.
    static func decryptPacket(_ data: Data) -> Data {
        Crypto.decode(data)
    }

    /// Get the magic from a decrypted packet.
    static func packetMagic(_ dec: Data) -> UInt16 {
        guard dec.count >= 2 else { return 0 }
        return dec.uint16LE(at: 0)
    }

    /// Get the command code from a decrypted packet.
    static func packetCmd(_ dec: Data) -> UInt16 {
        guard dec.count >= 10 else { return 0 }
        return dec.uint16LE(at: 8)
    }

    /// Parse a decrypted query response to extract relay server list.
    static func parseQueryResponse(_ dec: Data) -> QueryResponse? {
        guard dec.count >= 88 else { return nil }
        guard dec.uint16LE(at: 0) == magic else { return nil }
        guard dec.uint16LE(at: 8) == cmdQueryRsp else { return nil }

        let uid = dec.asciiString(at: 20, maxLength: 20)
        var relayServers: [Endpoint] = []
        for i in 0..<4 {
            let offset = 72 + i * 4
            guard offset + 4 <= dec.count else { break }
            let ip = dec.ipString(at: offset)
            relayServers.append(Endpoint(host: ip, port: 20001))
        }
        let vpgID = dec.count > 43 ? Data(dec[40..<44]) : Data()

        return QueryResponse(
            uid: uid, relayServers: relayServers,
            vpgID: vpgID, raw: dec
        )
    }

    /// Parse a decrypted relay stream response.
    ///
    /// Layout:
    ///   - `[0x14]` client source port (2 bytes BE)
    ///   - `[0x16]` relay port (2 bytes BE)
    ///   - `[0x18]` relay IP (4 bytes, network order)
    ///   - `[0x48]` session token (4 bytes LE)
    ///   - `[0x4c]` KCP conv (4 bytes LE)
    static func parseRelayStreamResponse(_ dec: Data) -> StreamResponse? {
        guard dec.count >= 0x1c else { return nil }
        guard dec.uint16LE(at: 0) == magic else { return nil }
        guard dec.uint16LE(at: 8) == cmdRlyStreamRsp else { return nil }

        let relayPort = dec.uint16BE(at: 0x16)
        let relayIP = dec.ipString(at: 0x18)

        var sessionToken: UInt32 = 0
        var kcpConv: UInt32 = 0
        if dec.count > 0x4f {
            sessionToken = dec.uint32LE(at: 0x48)
            kcpConv = dec.uint32LE(at: 0x4c)
        }

        return StreamResponse(
            relayIP: relayIP, relayPort: relayPort,
            sessionToken: sessionToken, kcpConv: kcpConv,
            raw: dec
        )
    }

    /// Parse a KCP segment header (24 bytes) from data at the given offset.
    static func parseKCPSegment(
        _ data: Data, at offset: Int = 0
    ) -> KCPSegment? {
        guard data.count - offset >= kcpHeaderSize else { return nil }
        return KCPSegment(
            conv: data.uint32LE(at: offset),
            cmd: data[data.startIndex + offset + 4],
            frg: data[data.startIndex + offset + 5],
            wnd: data.uint16LE(at: offset + 6),
            ts: data.uint32LE(at: offset + 8),
            sn: data.uint32LE(at: offset + 12),
            una: data.uint32LE(at: offset + 16),
            len: data.uint32LE(at: offset + 20),
            dataOffset: offset + kcpHeaderSize
        )
    }

    /// Build a KCP ACK segment.
    static func buildKCPAck(
        conv: UInt32, sn: UInt32, ts: UInt32,
        una: UInt32, wnd: UInt16 = 256
    ) -> Data {
        var data = Data(count: kcpHeaderSize)
        data.writeUInt32LE(conv, at: 0)
        data[4] = kcpCmdAck
        data[5] = 0
        data.writeUInt16LE(wnd, at: 6)
        data.writeUInt32LE(ts, at: 8)
        data.writeUInt32LE(sn, at: 12)
        data.writeUInt32LE(una, at: 16)
        data.writeUInt32LE(0, at: 20)
        return data
    }
}
