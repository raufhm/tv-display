// Sends the Mac's sound to the TV: a Core Audio process tap (macOS 14.2+) captures everything
// the Mac plays and mutes it locally, then the PCM goes to the TV on the video connection.

import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.2, *)
final class AudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "audio", qos: .userInteractive)
    /// Called with interleaved 16-bit PCM (sample rate, channels, data).
    var onPCM: ((Int, Int, Data) -> Void)?
    private(set) var sampleRate = 48000
    private(set) var channels = 2

    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "TV Display"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped // silent on the Mac while the TV plays it
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create audio tap")

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt), "read tap format")
        sampleRate = Int(fmt.mSampleRate)
        channels = Int(fmt.mChannelsPerFrame)
        let interleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let outputUID = try defaultOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TV Display Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID), "create aggregate device")

        let rate = sampleRate, ch = channels
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let onPCM = self.onPCM else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = abl.first, let src = first.mData else { return }
            // Tap delivers Float32; convert to interleaved Int16 (half the bytes, plenty for speech/video).
            if interleaved {
                let n = Int(first.mDataByteSize) / 4
                let f = src.assumingMemoryBound(to: Float.self)
                var out = Data(count: n * 2)
                out.withUnsafeMutableBytes { raw in
                    let o = raw.bindMemory(to: Int16.self)
                    for i in 0..<n { o[i] = Int16(max(-1, min(1, f[i])) * 32767).littleEndian }
                }
                onPCM(rate, ch, out)
            } else {
                let frames = Int(first.mDataByteSize) / 4
                var out = Data(count: frames * ch * 2)
                out.withUnsafeMutableBytes { raw in
                    let o = raw.bindMemory(to: Int16.self)
                    for c in 0..<min(ch, abl.count) {
                        guard let p = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<frames { o[i * ch + c] = Int16(max(-1, min(1, p[i])) * 32767).littleEndian }
                    }
                }
                onPCM(rate, ch, out)
            }
        }, "create audio callback")
        try check(AudioDeviceStart(aggregateID, procID), "start audio")
        log("audio: sending Mac sound to the TV (\(sampleRate) Hz, \(channels) ch)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            log("audio: back on the Mac")
        }
    }

    deinit { stop() }

    private func defaultOutputUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev),
                  "find output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "read output device")
        guard let uid else { throw StreamError("No audio output device.") }
        return uid.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw StreamError("Couldn't \(what) (\(status)).") }
    }
}
