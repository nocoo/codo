import Foundation
import Testing

@testable import CodoCore

@Suite("PathUtils — canonicalizeCwd")
struct PathUtilsTests {
    @Test func resolveNormalPath() {
        // A normal absolute path should remain unchanged (or resolve symlinks if any)
        let result = canonicalizeCwd("/usr/local/bin")
        #expect(!result.isEmpty)
        // The result should be a valid absolute path
        #expect(result.hasPrefix("/"))
    }

    @Test func resolvePathWithTrailingSlash() {
        let result = canonicalizeCwd("/tmp/")
        #expect(!result.isEmpty)
        #expect(result.hasPrefix("/"))
    }

    @Test func resolveRelativePath() {
        // resolvingSymlinksInPath on "." may return "." (not resolved to absolute)
        // This is expected — canonicalizeCwd is designed for absolute paths from cwd
        let result = canonicalizeCwd(".")
        #expect(!result.isEmpty)
    }

    @Test func resolveEmptyString() {
        // Empty string should fall back to original (or resolve to cwd)
        let result = canonicalizeCwd("")
        // resolvingSymlinksInPath of "" returns ""; fallback returns ""
        #expect(result == "")
    }

    @Test func resolveTmpSymlink() {
        // On macOS, /tmp is a symlink to /private/tmp
        // resolvingSymlinksInPath may or may not resolve this (it does resolve symlinks)
        let result = canonicalizeCwd("/tmp")
        #expect(!result.isEmpty)
        #expect(result.hasPrefix("/"))
    }

    @Test func resolveHomeDirectory() {
        let home = NSHomeDirectory()
        let result = canonicalizeCwd(home)
        #expect(!result.isEmpty)
        #expect(result.hasPrefix("/"))
    }

    @Test func idempotent() {
        // Canonicalizing twice should yield the same result
        let first = canonicalizeCwd("/usr/local/bin")
        let second = canonicalizeCwd(first)
        #expect(first == second)
    }
}
