import XCTest
import CLibUSB

final class LibUSBLinkageTests: XCTestCase {
    func test_libusbInitialisesAndExits() {
        var context: OpaquePointer?
        XCTAssertEqual(libusb_init(&context), 0)
        libusb_exit(context)
    }
}
