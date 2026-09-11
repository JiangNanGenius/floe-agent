import Foundation

/// Central byte-cap registry. Tools previously hard-coded caps (4/8/10/16/
/// 20/64/128 MiB) and several guard defaults silently shadowed larger tool
/// limits. Every cap now has one name and one value.
public enum FileLimits {
    public static let workspaceRead = 10 * 1024 * 1024
    public static let workspaceWrite = 4 * 1024 * 1024
    public static let pdf = 64 * 1024 * 1024
    public static let officeRead = 256 * 1024 * 1024
    public static let officeWrite = 128 * 1024 * 1024
    public static let documentConversion = 16 * 1024 * 1024
    public static let imageInput = 16 * 1024 * 1024
    public static let artifactImage = 20 * 1024 * 1024
    public static let inlineImage = 8 * 1024 * 1024
    public static let jobDownload = 2 * 1024 * 1024 * 1024
}
