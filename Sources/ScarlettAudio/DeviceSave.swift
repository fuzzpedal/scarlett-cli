import Foundation
import CLibUSB

/// Vendor protocol for the Gen 1 Scarlett, documented in Linux
/// `sound/usb/mixer_scarlett.c` and verified against this 18i20 on 2026-09-10.
///
/// Every request targets interface 0. Interface 5 is the DFU (firmware)
/// interface: a class request to it is a DFU_UPLOAD, which wedges the control
/// pipe and knocks the device off the USB bus until it is power-cycled. Do not
/// enumerate or sweep interfaces here.
enum SaveProtocol {
    static let vendorID: UInt16 = 0x1235
    static let productID: UInt16 = 0x800c
    static let interface: UInt16 = 0
    static let requestSave: UInt8 = 0x03
    static let valueSave: UInt16 = 0x005a
    static let unitSave: UInt16 = 0x3c
    static let magic: UInt8 = 0xa5

    static var indexSave: UInt16 { (unitSave << 8) | interface }
}

enum SaveError: Error, Equatable, CustomStringConvertible {
    case libusbInitFailed(Int32)
    case deviceNotFoundOnUSB
    case openFailed(Int32)
    case transferFailed(Int32)

    var description: String {
        switch self {
        case .libusbInitFailed(let code):
            return "Could not initialise libusb (code \(code))"
        case .deviceNotFoundOnUSB:
            return "No Scarlett 18i20 found on USB (looked for 1235:800c). "
                + "The interface can be present in Core Audio and absent from "
                + "USB — check the cable and that the unit is powered."
        case .openFailed(let code):
            return "Could not open the interface over USB (libusb code \(code))"
        case .transferFailed(let code):
            return "The device rejected the save request (libusb code \(code)). "
                + "Settings were not persisted."
        }
    }
}

/// Tells the interface to commit its current configuration to flash, so it
/// survives a power cycle. This saves the device's *entire* configuration,
/// not just the clock source.
func saveToHardware() throws {
    var context: OpaquePointer?
    let initResult = libusb_init(&context)
    guard initResult == 0 else { throw SaveError.libusbInitFailed(initResult) }
    defer { libusb_exit(context) }

    var list: UnsafeMutablePointer<OpaquePointer?>?
    let count = libusb_get_device_list(context, &list)
    defer { if let list { libusb_free_device_list(list, 1) } }
    guard count > 0, let list else { throw SaveError.deviceNotFoundOnUSB }

    var handle: OpaquePointer?
    for index in 0..<Int(count) {
        guard let device = list[index] else { continue }
        var descriptor = libusb_device_descriptor()
        guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
        guard descriptor.idVendor == SaveProtocol.vendorID,
              descriptor.idProduct == SaveProtocol.productID else { continue }

        let openResult = libusb_open(device, &handle)
        guard openResult == 0 else { throw SaveError.openFailed(openResult) }
        break
    }
    guard let handle else { throw SaveError.deviceNotFoundOnUSB }
    defer { libusb_close(handle) }

    var payload = SaveProtocol.magic
    // 0x21 = host-to-device | class request | interface recipient.
    // No retry: a wedged control pipe does not recover without a replug, so a
    // second attempt would only hide the failure.
    let sent = libusb_control_transfer(
        handle,
        0x21,
        SaveProtocol.requestSave,
        SaveProtocol.valueSave,
        SaveProtocol.indexSave,
        &payload,
        1,
        2000
    )
    guard sent == 1 else { throw SaveError.transferFailed(sent) }
}
