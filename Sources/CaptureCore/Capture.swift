import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

/// Native stream lifecycle is controlled by the session; callbacks only publish
/// immutable buffers. ScreenCaptureKit follows the selected app's audio helpers.
final class NativeCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lane: CaptureInput
    private let bundle: String
    private let micLane: CaptureInput
    private let microphone: InputDevice
    private var stream: SCStream?
    private var pid: pid_t = 0
    private let selectedPID: pid_t?

    init(bundle: String, microphone: InputDevice, lane: CaptureInput, micLane: CaptureInput, processID: pid_t? = nil) throws {
        self.bundle = bundle; self.lane = lane; self.micLane = micLane; self.microphone = microphone
        selectedPID = processID
        _ = try Hardware.resolveApp(bundle, processID: processID)
    }

    func prepare() async throws -> SCContentFilter {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw ScreenCaptureAccess.explain(error) }
        let matches = content.applications.filter { $0.bundleIdentifier == bundle && (selectedPID == nil || $0.processID == selectedPID) }
        guard matches.count == 1, let app = matches.first else {
            throw CaptureError.message("ScreenCaptureKit requires one running app matching \(bundle). Open its window and start playback.")
        }
        guard let display = content.displays.first else {
            throw CaptureError.message("No display is available for the application's audio filter")
        }
        pid = app.processID
        diagnostic("Selected capture app: \(app.bundleIdentifier), pid \(app.processID)")
        return SCContentFilter(display: display, including: [app], exceptingWindows: [])
    }

    func start(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        guard let captureDevice = AVCaptureDevice(uniqueID: microphone.uid) else {
            throw CaptureError.message("Selected microphone is unavailable to the capture framework: \(microphone.name)")
        }
        config.microphoneCaptureDeviceID = captureDevice.uniqueID
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "capture-it.app.callback", qos: .userInteractive))
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "capture-it.mic.callback", qos: .userInteractive))
        do { try await stream.startCapture() }
        catch { throw ScreenCaptureAccess.explain(error) }
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        let lane = type == .audio ? self.lane : micLane
        guard sample.isValid, CMSampleBufferDataIsReady(sample) else { return }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return }
        guard count <= 65_536,
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            lane.copyFailure.store(true, ordering: .releasing); return
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard status == noErr else { lane.copyFailure.store(true, ordering: .releasing); return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time.isFinite, time >= 0 else { lane.copyFailure.store(true, ordering: .releasing); return }
        lane.acceptOwned(buffer, hostTime: AVAudioTime.hostTime(forSeconds: time))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lane.copyFailure.store(true, ordering: .releasing)
    }

    func refresh() throws {
        guard pid > 0, kill(pid, 0) == 0 else { throw CaptureError.message("Selected application exited") }
        guard try Hardware.devices().contains(where: { $0.uid == microphone.uid }) else { throw CaptureError.message("Selected microphone disconnected") }
    }

    func stop() async throws {
        let stopping = stream
        stream = nil
        try await stopping?.stopCapture()
    }
}

enum ScreenCaptureAccess {
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func explain(_ error: Error) -> Error {
        let native = error as NSError
        guard native.domain == SCStreamErrorDomain, native.code == SCStreamError.Code.userDeclined.rawValue else { return error }
        return CaptureError.message("ScreenCaptureKit could not access screen recording for this launch (\(native.domain) \(native.code)). In System Settings → Privacy & Security → Screen & System Audio Recording, enable the terminal or capture-it entry in the screen and audio section. After granting access, quit and reopen the terminal, then rerun capture-it from the same installed path.")
    }
}

enum MicrophoneAccess {
    static func authorize() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return }
        guard status == .notDetermined, await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message("Microphone permission denied. Allow capture-it (or your terminal) in System Settings > Privacy & Security > Microphone.")
        }
    }
}
