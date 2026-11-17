import CaptureCore
import Foundation
import Darwin

@main struct Main {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGXFSZ, SIG_IGN) // File-size limits become reported write errors.
        do { exit(try await CLI.run(Array(CommandLine.arguments.dropFirst()))) }
        catch { FileHandle.standardError.write(Data("capture-it: \(error)\n".utf8)); exit(1) }
    }
}
