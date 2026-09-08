import CoreAudio
import Foundation

enum HALError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case noStreams(String)
    case formatNotAvailable(rate: Double, bits: UInt32)
    case osStatus(OSStatus, String)

    var description: String {
        switch self {
        case .deviceNotFound(let query):
            return "No audio device found matching \"\(query)\""
        case .noStreams(let name):
            return "Device \"\(name)\" has no audio streams"
        case .formatNotAvailable(let rate, let bits):
            return "No \(bits)-bit format available at \(rate) Hz"
        case .osStatus(let status, let context):
            return "\(context) failed with OSStatus \(status)"
        }
    }
}

private func propertyDataSize(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress
) throws -> UInt32 {
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyDataSize")
    }
    return size
}

private func getPropertyArray<T>(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress,
    as type: T.Type
) throws -> [T] {
    var size = try propertyDataSize(objectID, &address)
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }

    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyData")
    }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

private func getPropertyValue<T>(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress,
    as type: T.Type
) throws -> T {
    var size = UInt32(MemoryLayout<T>.stride)
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { buffer.deallocate() }

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyData")
    }
    return buffer.pointee
}

private func setPropertyValue<T>(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress,
    to value: T
) throws {
    var mutableValue = value
    let size = UInt32(MemoryLayout<T>.stride)
    let status = withUnsafeBytes(of: &mutableValue) { buffer in
        AudioObjectSetPropertyData(objectID, &address, 0, nil, size, buffer.baseAddress!)
    }
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectSetPropertyData")
    }
}

private func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func deviceName(_ id: AudioObjectID) throws -> String {
    var propertyAddress = address(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<CFString?>.stride)
    var cfName: CFString?

    let status = withUnsafeMutablePointer(to: &cfName) { pointer -> OSStatus in
        AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &size, pointer)
    }
    guard status == noErr, let name = cfName else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyData(kAudioObjectPropertyName)")
    }
    return name as String
}

func findDevice(nameContains query: String) throws -> AudioObjectID {
    var propertyAddress = address(kAudioHardwarePropertyDevices)
    let deviceIDs: [AudioObjectID] = try getPropertyArray(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        as: AudioObjectID.self
    )

    for id in deviceIDs {
        if let name = try? deviceName(id), name.localizedCaseInsensitiveContains(query) {
            return id
        }
    }
    throw HALError.deviceNotFound(query)
}

func nominalSampleRate(_ id: AudioObjectID) throws -> Double {
    var propertyAddress = address(kAudioDevicePropertyNominalSampleRate)
    return try getPropertyValue(id, &propertyAddress, as: Float64.self)
}

func setNominalSampleRate(_ id: AudioObjectID, to rate: Double) throws {
    var propertyAddress = address(kAudioDevicePropertyNominalSampleRate)
    try setPropertyValue(id, &propertyAddress, to: Float64(rate))
}

func availableSampleRates(_ id: AudioObjectID) throws -> [Double] {
    var propertyAddress = address(kAudioDevicePropertyAvailableNominalSampleRates)
    let ranges: [AudioValueRange] = try getPropertyArray(
        id, &propertyAddress, as: AudioValueRange.self
    )
    return discreteRates(fromRanges: ranges.map { (min: $0.mMinimum, max: $0.mMaximum) })
}

func streamIDs(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
    var propertyAddress = address(kAudioDevicePropertyStreams, scope: scope)
    return try getPropertyArray(id, &propertyAddress, as: AudioObjectID.self)
}

func physicalFormat(_ streamID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var propertyAddress = address(kAudioStreamPropertyPhysicalFormat)
    return try getPropertyValue(streamID, &propertyAddress, as: AudioStreamBasicDescription.self)
}

func setPhysicalFormat(_ streamID: AudioObjectID, to format: AudioStreamBasicDescription) throws {
    var propertyAddress = address(kAudioStreamPropertyPhysicalFormat)
    try setPropertyValue(streamID, &propertyAddress, to: format)
}

func availablePhysicalFormats(_ streamID: AudioObjectID) throws -> [AudioStreamBasicDescription] {
    var propertyAddress = address(kAudioStreamPropertyAvailablePhysicalFormats)
    let ranged: [AudioStreamRangedDescription] = try getPropertyArray(
        streamID, &propertyAddress, as: AudioStreamRangedDescription.self
    )
    return ranged.map { $0.mFormat }
}
