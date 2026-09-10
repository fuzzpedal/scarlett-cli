import XCTest
@testable import ScarlettAudio

final class DeviceSaveTests: XCTestCase {
    func test_protocolConstantsMatchVerifiedValues() {
        XCTAssertEqual(SaveProtocol.vendorID, 0x1235)
        XCTAssertEqual(SaveProtocol.productID, 0x800c)
        XCTAssertEqual(SaveProtocol.requestSave, 0x03)
        XCTAssertEqual(SaveProtocol.valueSave, 0x005a)
        XCTAssertEqual(SaveProtocol.magic, 0xa5)
        XCTAssertEqual(SaveProtocol.indexSave, 0x3c00)
    }

    /// Interface 5 is the DFU (firmware) interface. Sending it anything wedges
    /// the control pipe and drops the device off the USB bus. This guards the
    /// constant against a careless edit.
    func test_targetsInterfaceZeroAndNeverTheDFUInterface() {
        XCTAssertEqual(SaveProtocol.interface, 0)
        XCTAssertNotEqual(SaveProtocol.interface, 5)
    }

    func test_errorsDescribeThemselves() {
        XCTAssertTrue(
            SaveError.deviceNotFoundOnUSB.description.contains("1235:800c")
        )
        XCTAssertTrue(
            SaveError.transferFailed(-9).description.contains("not persisted")
        )
    }
}
