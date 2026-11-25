// Compiled with CaptureCore sources only by the optional local mic journey.
// Reads process/device metadata; this helper does not open a microphone.
import Foundation

@main struct MicrophoneProbe {
    static func main() throws {
        let bundle = CommandLine.arguments[1]
        let pid = Int32(CommandLine.arguments[2])!
        let active = try Hardware.activeInputDevices(bundle: bundle, processID: pid)
        let target = AppChoice(name: bundle, bundleID: bundle, pid: pid)
        let choice = try Hardware.selectMicrophone(explicitUID: nil, targets: [target])
        struct Report: Encodable { let activeDeviceIDs: [UInt32]; let uid: String; let source: String; let reason: String }
        let data = try JSONEncoder().encode(Report(activeDeviceIDs: active.sorted(), uid: choice.device.uid, source: choice.source, reason: choice.reason))
        print(String(decoding: data, as: UTF8.self))
    }
}
