import Testing

@testable import CodoCore

@Test func codoCoreVersion() {
    #expect(CodoInfo.version == "0.2.0")
}
