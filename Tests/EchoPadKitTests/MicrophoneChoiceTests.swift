import CoreAudio
import XCTest
@testable import EchoPadKit
@testable import SystemAudioKit

final class MicrophoneChoiceTests: XCTestCase {
    private func device(_ uid: String, _ name: String, _ transport: AudioDevice.Transport, isDefault: Bool = false) -> AudioDevice {
        AudioDevice(id: AudioDeviceID(0), uid: uid, name: name, isDefault: isDefault, transport: transport)
    }

    func testBluetoothDefaultGivesWayToTheBuiltInMicrophone() {
        let inputs = [device("headset", "Zone Vibe 100", .bluetooth, isDefault: true),
                      device("usb-cam", "Webcam", .usb),
                      device("builtin", "MacBook Pro Microphone", .builtIn)]
        let choice = RecordingController.unpinnedMicrophone(among: inputs)
        XCTAssertEqual(choice.microphone, .device(uid: "builtin"))
        XCTAssertEqual(choice.notice, "Using MacBook Pro Microphone: the default input is a Bluetooth headset")
    }

    func testOtherDefaultsStay() {
        for transport: AudioDevice.Transport in [.builtIn, .usb, .other] {
            let inputs = [device("default", "Default", transport, isDefault: true),
                          device("headset", "AirPods", .bluetooth),
                          device("builtin", "MacBook Pro Microphone", .builtIn)]
            let choice = RecordingController.unpinnedMicrophone(among: inputs)
            XCTAssertEqual(choice.microphone, .systemDefault, "\(transport)")
            XCTAssertNil(choice.notice)
        }
    }

    func testBluetoothDefaultWithoutBuiltInMicrophoneStays() {
        let inputs = [device("headset", "AirPods", .bluetooth, isDefault: true), device("usb", "USB Mic", .usb)]
        let choice = RecordingController.unpinnedMicrophone(among: inputs)
        XCTAssertEqual(choice.microphone, .systemDefault)
        XCTAssertNil(choice.notice)
    }

    func testNoDefaultOrNoInputsStay() {
        XCTAssertEqual(RecordingController.unpinnedMicrophone(among: []).microphone, .systemDefault)
        let inputs = [device("headset", "AirPods", .bluetooth), device("builtin", "MacBook Pro Microphone", .builtIn)]
        XCTAssertEqual(RecordingController.unpinnedMicrophone(among: inputs).microphone, .systemDefault)
    }
}
