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
        #expect(msg.subtitle == nil)
        #expect(msg.threadId == nil)
    }

    @Test func decodeMinimal() throws {
        let json = #"{"title":"T"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.title == "T")
        #expect(msg.body == nil)
        #expect(msg.sound == nil)
        #expect(msg.subtitle == nil)
        #expect(msg.threadId == nil)
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

    @Test func decodeWithSubtitleAndThreadId() throws {
        let json = #"{"title":"T","subtitle":"✅ Success","threadId":"build"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.title == "T")
        #expect(msg.subtitle == "✅ Success")
        #expect(msg.threadId == "build")
    }

    @Test func decodeAllFields() throws {
        let json = #"{"title":"T","body":"B","subtitle":"S","sound":"none","threadId":"tid"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.title == "T")
        #expect(msg.body == "B")
        #expect(msg.subtitle == "S")
        #expect(msg.sound == "none")
        #expect(msg.threadId == "tid")
    }

    @Test func encodeWithSubtitleAndThreadId() throws {
        let msg = CodoMessage(title: "T", subtitle: "S", threadId: "tid")
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["title"] as? String == "T")
        #expect(obj?["subtitle"] as? String == "S")
        #expect(obj?["threadId"] as? String == "tid")
        #expect(obj?["body"] == nil)
        #expect(obj?["sound"] == nil)
    }

    @Test func backwardCompatOldJson() throws {
        // Old 3-field JSON still decodes fine (new fields default to nil)
        let json = #"{"title":"T","body":"B","sound":"default"}"#
        let msg = try decoder.decode(CodoMessage.self, from: Data(json.utf8))
        #expect(msg.subtitle == nil)
        #expect(msg.threadId == nil)
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
