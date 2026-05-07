import Foundation

public protocol NetworkSnapshotCollecting {
    func collect() throws -> NetworkSnapshot
}

public protocol CommandRunning: Sendable {
    func run(executablePath: String, arguments: [String]) throws -> String
}

public enum CommandRunnerError: Error, Equatable {
    case nonZeroExit(Int32, String)
    case unreadableOutput
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: error, encoding: .utf8) ?? ""
            throw CommandRunnerError.nonZeroExit(process.terminationStatus, message)
        }

        guard let text = String(data: output, encoding: .utf8) else {
            throw CommandRunnerError.unreadableOutput
        }

        return text
    }
}

public struct NettopCollector: NetworkSnapshotCollecting {
    private let runner: CommandRunning
    private let parser: NettopCSVParser

    public init(runner: CommandRunning = ProcessCommandRunner(), parser: NettopCSVParser = NettopCSVParser()) {
        self.runner = runner
        self.parser = parser
    }

    public func collect() throws -> NetworkSnapshot {
        let output = try runner.run(
            executablePath: "/usr/bin/nettop",
            arguments: ["-L", "1", "-x", "-n"]
        )
        return try parser.parse(output, timestamp: Date())
    }
}
