// Controlled test app: a quiet mono tone, never microphone input or networking.
import AppKit
import AVFoundation
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 240, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "capture-it audio test"
window.orderFrontRegardless()
let argument = CommandLine.arguments.dropFirst().first ?? "440"
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let format: AVAudioFormat
let buffer: AVAudioPCMBuffer
if let frequency = Double(argument) {
    format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for index in 0 ..< 48_000 {
        buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 48_000)) * 0.03
    }
} else {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: argument))
    format = file.processingFormat
    let speechFrames = AVAudioFrameCount(file.length)
    let capacity = speechFrames + AVAudioFrameCount(format.sampleRate * 2)
    buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    try file.read(into: buffer, frameCount: speechFrames)
    for channel in 0 ..< Int(format.channelCount) {
        let samples = buffer.floatChannelData![channel]
        for index in 0 ..< Int(speechFrames) { samples[index] *= 0.05 }
        samples.advanced(by: Int(speechFrames)).update(repeating: 0, count: Int(capacity - speechFrames))
    }
    buffer.frameLength = capacity
}
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
try engine.start()
player.scheduleBuffer(buffer, at: nil, options: .loops)
player.play()
print("ready \(Bundle.main.bundleIdentifier ?? "unknown")")
fflush(stdout)
app.run()
