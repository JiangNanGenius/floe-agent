import Foundation

public enum MusicNativeBuiltins {
    public static let synth = "floe.synth"
    public static let eq = "floe.eq"
    public static let reverb = "floe.reverb"
}

public enum MusicNativeError: Error, Sendable {
    case invalid(String)
    case unsupported(String)
    case staleOwner
    case encoder(Int32)
    case render(String)
}
