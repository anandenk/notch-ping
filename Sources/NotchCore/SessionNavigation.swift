import Foundation

public enum SessionDestination: Equatable, Sendable {
    case app(OriginApp)
    case unknown

    public init(origin: OriginApp?, workspace: String? = nil) {
        if let origin { self = .app(origin) }
        else if let workspace, !workspace.isEmpty { self = .app(.cmux) }
        else { self = .unknown }
    }
}
