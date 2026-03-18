import Foundation
import Testing

@testable import CodoCore

// MARK: - CodoMessage Decode

@Suite("CodoMessage Decoding")
struct CodoMessageDecodeTests {
    let decoder = JSONDecoder()

    @Test func decodeFullMessage() throws {
        let json = #"{"title":"T","body":"B","sound":"default"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.title == "T")
        #expect(msg.body == "B")
        #expect(msg.sound == "default")
    }

    @Test func decodeMinimal() throws {
        let json = #"{"title":"T"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.title == "T")
        #expect(msg.body == nil)
        #expect(msg.sound == nil)
    }

    @Test func decodeMissingTitle() throws {
        let json = #"{"body":"B"}"#
        #expect(throws: DecodingError.self) {
            try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        }
    }

    @Test func decodeEmptyString() throws {
        let json = ""
        #expect(throws: (any Error).self) {
            try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        }
    }

    @Test func decodeGarbage() throws {
        let json = "not json at all"
        #expect(throws: (any Error).self) {
            try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        }
    }

    @Test func decodeEmptyTitle() throws {
        let json = #"{"title":""}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.title == "")
    }

    @Test func decodeSoundNone() throws {
        let json = #"{"title":"T","sound":"none"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.sound == "none")
    }

    @Test func effectiveSoundDefault() throws {
        let json = #"{"title":"T"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.effectiveSound == "default")
    }

    @Test func effectiveSoundExplicit() throws {
        let json = #"{"title":"T","sound":"none"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.effectiveSound == "none")
    }
}

// MARK: - CodoMessage Validation

@Suite("CodoMessage Validation")
struct CodoMessageValidationTests {
    @Test func validateValidMessage() {
        let msg = CodoMessage(title: "T", body: nil, sound: nil)
        #expect(msg.validate() == nil)
    }

    @Test func validateEmptyTitle() {
        let msg = CodoMessage(title: "", body: nil, sound: nil)
        #expect(msg.validate() == "title is required")
    }

    @Test func validateWhitespaceTitle() {
        let msg = CodoMessage(title: "   ", body: nil, sound: nil)
        #expect(msg.validate() == "title is required")
    }
}

// MARK: - CodoResponse Encode

@Suite("CodoResponse Encoding")
struct CodoResponseEncodeTests {
    let encoder = JSONEncoder()

    @Test func encodeOk() throws {
        let resp = CodoResponse.ok
        let data = try encoder.encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["ok"] as? Bool == true)
        #expect(json?["error"] == nil)
    }

    @Test func encodeError() throws {
        let resp = CodoResponse.error("something failed")
        let data = try encoder.encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["ok"] as? Bool == false)
        #expect(json?["error"] as? String == "something failed")
    }
}

// MARK: - CodoResponse Decode (for CLI client testing)

@Suite("CodoResponse Decoding")
struct CodoResponseDecodeTests {
    let decoder = JSONDecoder()

    @Test func decodeOk() throws {
        let json = #"{"ok":true}"#
        let resp = try decoder.decode(CodoResponse.self, from: Data(json.utf8))
        #expect(resp.isOk == true)
        #expect(resp.errorMessage == nil)
    }

    @Test func decodeError() throws {
        let json = #"{"ok":false,"error":"denied"}"#
        let resp = try decoder.decode(CodoResponse.self, from: Data(json.utf8))
        #expect(resp.isOk == false)
        #expect(resp.errorMessage == "denied")
    }
}
