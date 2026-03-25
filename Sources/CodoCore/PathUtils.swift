import Foundation

/// Best-effort symlink resolution using NSString.resolvingSymlinksInPath.
/// Note: behavior may differ from POSIX realpath(3) in edge cases (e.g. /private prefix handling).
/// If exact parity with TS realpathSync is needed, consider wrapping Darwin.realpath() instead.
/// Falls back to original input on empty result.
public func canonicalizeCwd(_ path: String) -> String {
    let resolved = (path as NSString).resolvingSymlinksInPath
    return resolved.isEmpty ? path : resolved
}
