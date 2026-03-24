import Foundation

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }
}

enum Log {
    static var level: LogLevel = .info

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func emit(
        _ level: LogLevel, _ message: String, file: String
    ) {
        guard level >= Self.level else { return }
        let time = formatter.string(from: Date())
        let module = URL(fileURLWithPath: file)
            .deletingPathExtension().lastPathComponent
        let line = "\(time) [\(level.label)] \(module): \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func debug(_ msg: String, file: String = #file) {
        emit(.debug, msg, file: file)
    }

    static func info(_ msg: String, file: String = #file) {
        emit(.info, msg, file: file)
    }

    static func warning(_ msg: String, file: String = #file) {
        emit(.warning, msg, file: file)
    }

    static func error(_ msg: String, file: String = #file) {
        emit(.error, msg, file: file)
    }
}
