import AppKit
import AVFoundation
import CoreAudio
import Foundation

func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var address = propertyAddress(selector, scope: scope)
    var result = initial
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &result) { pointer in
        try checkAudio(AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer), "Read audio property \(selector) on object \(id)")
    }
    return result
}

func audioIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    try checkAudio(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Read audio list size")
    guard size > 0 else { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try result.withUnsafeMutableBytes { bytes in
        try checkAudio(AudioObjectGetPropertyData(id, &address, 0, nil, &size, bytes.baseAddress!), "Read audio list")
    }
    return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = propertyAddress(selector)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try checkAudio(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result), "Read audio name")
    return result?.takeRetainedValue() as String? ?? ""
}

public struct AudioApp: Codable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String
    public let name: String
    public let playing: Bool
}

public struct InputDevice: Codable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let isDefault: Bool
}

public enum Hardware {
    public static func apps() throws -> [AudioApp] {
        try audioIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            do {
            let pid = try audioValue(id, kAudioProcessPropertyPID, initial: pid_t(0))
            let bundle = try audioString(id, kAudioProcessPropertyBundleID)
            let playing = try audioValue(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0
            let app = NSRunningApplication(processIdentifier: pid)
            return AudioApp(objectID: id, pid: pid, bundleID: bundle, name: app?.localizedName ?? bundle, playing: playing)
            } catch CaptureError.audio(let status, _) where status == kAudioHardwareBadObjectError {
                // A process can disappear between enumeration and its property reads.
                return nil
            }
        }.sorted { ($0.bundleID, $0.pid) < ($1.bundleID, $1.pid) }
    }

    public static func devices() throws -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultID = try audioValue(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
        return try audioIDs(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard !(try audioIDs(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)).isEmpty else { return nil }
            return InputDevice(id: id, uid: try audioString(id, kAudioDevicePropertyDeviceUID), name: try audioString(id, kAudioObjectPropertyName), isDefault: id == defaultID)
        }
    }

    static func resolveApp(_ bundle: String, processID: pid_t? = nil) throws -> [AudioApp] {
        guard !bundle.isEmpty else { throw CaptureError.message("An exact app bundle identifier is required") }
        if let processID {
            guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated, app.bundleIdentifier == bundle else {
                throw CaptureError.message("Selected app exited or changed before capture began")
            }
        }
        let roots = processID.map { Set([$0]) } ?? Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        guard roots.count <= 1 else { throw CaptureError.message("Multiple running apps have bundle identifier \(bundle); choose a unique application") }
        let matches = try apps().filter { app in
            app.bundleID == bundle || app.bundleID.hasPrefix(bundle + ".") || isDescendant(app.pid, of: roots)
        }
        guard !matches.isEmpty else { throw CaptureError.message("No audio process found for \(bundle). Open the app and start audio first; run capture-it apps.") }
        if roots.isEmpty && matches.filter({ $0.bundleID == bundle }).count > 1 {
            throw CaptureError.message("\(bundle) is shared by several audio helpers; select their owning application's bundle identifier")
        }
        return matches
    }

    private static func isDescendant(_ pid: pid_t, of roots: Set<pid_t>) -> Bool {
        var current = pid
        for _ in 0 ..< 32 {
            if roots.contains(current) { return true }
            guard current > 1 else { break }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let parent = info.kp_eproc.e_ppid
            if parent == current { break }
            current = parent
        }
        return false
    }

    /// Read only active input streams owned by the chosen app or its helpers.
    /// No active stream, multiple devices or unsupported inspection is unknown.
    static func activeInputDevices(bundle: String, processID: pid_t?) throws -> Set<UInt32> {
        let roots = processID.map { Set([$0]) } ?? Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        let uniqueApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count == 1
        let related = try apps().filter { app in
            roots.contains(app.pid) || isDescendant(app.pid, of: roots) || (uniqueApp && (app.bundleID == bundle || app.bundleID.hasPrefix(bundle + ".")))
        }
        var devices: Set<UInt32> = []
        for app in related {
            let active = try audioValue(app.objectID, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))
            if active != 0 {
                devices.formUnion(try audioIDs(app.objectID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
            }
        }
        return devices
    }

    static func selectMicrophone(explicitUID: String?, bundle: String, processID: pid_t?) throws -> MicrophoneChoice {
        let available = try devices()
        var active: Set<UInt32>?
        if explicitUID == nil {
            do { active = try activeInputDevices(bundle: bundle, processID: processID) }
            catch { active = nil } // Optional passive probe; the documented fallback is the default.
        }
        return try MicrophonePolicy.choose(explicitUID: explicitUID, devices: available, activeAppDevices: active,
                                           canCapture: { AVCaptureDevice(uniqueID: $0.uid) != nil })
    }
}
