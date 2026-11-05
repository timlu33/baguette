import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A blocking TCP client socket to `127.0.0.1` — the far end of an
/// `adb forward`. POSIX on purpose: the scrcpy video stream is a plain
/// byte pipe read on a dedicated thread, which wants none of the
/// machinery of NIO or `URLSession`. Integration-only.
final class TCPConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var shut = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = Self.closeDescriptor(descriptor)
    }

    /// Connect to `127.0.0.1:port`. Throws when the port refuses —
    /// which, for an adb forward whose device side is not listening
    /// yet, is a normal "try again" answer.
    static func connect(port: Int) throws -> TCPConnection {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw AndroidError.adbFailed("socket(): errno \(errno)") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin_or_Glibc_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            _ = closeDescriptor(fd)
            throw AndroidError.adbFailed("connect(127.0.0.1:\(port)): errno \(code)")
        }

        var on: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return TCPConnection(descriptor: fd)
    }

    /// Bound how long a read may block; `0` removes the bound. A timed-out
    /// read answers `nil`, like a closed peer.
    func setReceiveTimeout(_ seconds: TimeInterval) {
        var value = timeval()
        value.tv_sec = numericCast(Int(seconds))
        value.tv_usec = numericCast(Int((seconds - Double(Int(seconds))) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size)
    }

    /// Up to `maxBytes`, blocking until some arrive. `nil` once the
    /// peer closed or `close()` was called.
    func read(maxBytes: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, maxBytes, 0) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Exactly `count` bytes, or `nil` if the stream ends first.
    func readExactly(_ count: Int) -> Data? {
        var out = Data()
        while out.count < count {
            guard let chunk = read(maxBytes: count - out.count) else { return nil }
            out.append(chunk)
        }
        return out
    }

    /// Write every byte. `false` when the socket is gone.
    func write(_ data: Data) -> Bool {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let count = bytes.withUnsafeBytes {
                send(descriptor, $0.baseAddress! + sent, bytes.count - sent, flags)
            }
            if count > 0 { sent += count; continue }
            if count < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Wake any blocked reader and refuse further traffic. The
    /// descriptor itself is released with the object, so a reader that
    /// is mid-`recv` can never be handed a recycled descriptor number.
    func close() {
        let first: Bool = lock.withLock {
            defer { shut = true }
            return !shut
        }
        if first { shutdown(descriptor, Int32(SHUT_RDWR)) }
    }

    private static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }
}

#if canImport(Darwin)
private let Darwin_or_Glibc_connect = Darwin.connect
#else
private let Darwin_or_Glibc_connect = Glibc.connect
#endif
