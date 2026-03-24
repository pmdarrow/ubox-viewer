import Foundation
import Darwin

enum SocketError: LocalizedError {
    case creationFailed
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .creationFailed: return "Failed to create UDP socket"
        case .bindFailed:     return "Failed to bind UDP socket"
        }
    }
}

final class UDPSocket {
    let fd: Int32
    let localPort: UInt16

    init() throws {
        let rawFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard rawFD >= 0 else { throw SocketError.creationFailed }

        let flags = fcntl(rawFD, F_GETFL)
        _ = fcntl(rawFD, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(INADDR_ANY).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(rawFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(rawFD)
            throw SocketError.bindFailed
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(rawFD, sockPtr, &addrLen)
            }
        }

        self.fd = rawFD
        self.localPort = UInt16(bigEndian: boundAddr.sin_port)
    }

    func send(_ data: Data, to endpoint: Endpoint) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        inet_pton(AF_INET, endpoint.host, &addr.sin_addr)

        data.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = Darwin.sendto(
                        fd, dataPtr.baseAddress, data.count, 0,
                        sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    func receive(maxSize: Int = 4096) -> (data: Data, from: Endpoint)? {
        var buffer = [UInt8](repeating: 0, count: maxSize)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.recvfrom(fd, &buffer, maxSize, 0, sockPtr, &addrLen)
            }
        }

        guard n > 0 else { return nil }

        var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sinAddr = addr.sin_addr
        inet_ntop(AF_INET, &sinAddr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostBuf)
        let port = UInt16(bigEndian: addr.sin_port)

        return (Data(buffer[..<n]), Endpoint(host: host, port: port))
    }

    func waitForData(timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(timeout * 1000)
        let result = Darwin.poll(&pfd, 1, ms)
        return result > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    func close() {
        Darwin.close(fd)
    }
}
