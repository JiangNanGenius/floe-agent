// Compiled with the exact router declaration extracted from HostAppDelegate.
// These synthetic inputs do not launch AppKit, a Bridge service, or an updater.
import Foundation

@main
struct HostBridgeURLRouterTests {
    static func main() {
        let connect = URL(string: "floe-bridge://connect")!
        let other = URL(string: "https://example.invalid/connect")!
        let wrongHost = URL(string: "floe-bridge://other")!
        precondition(!HostBridgeURLRouter.recognizes([]))
        precondition(!HostBridgeURLRouter.recognizes([other, wrongHost]))
        precondition(HostBridgeURLRouter.recognizes([other, connect]))

        // A cold-start link is held until the window and first-run selection
        // are ready. Multiple links coalesce into one presentation.
        var cold = HostBridgeURLRouter()
        precondition(!cold.receive([connect]))
        precondition(!cold.receive([connect]))
        precondition(!cold.setReady(false))
        precondition(cold.setReady(true))
        precondition(!cold.setReady(true))

        // Once ready, each recognized callback presents immediately; invalid
        // callbacks neither present nor create latent work.
        precondition(!cold.receive([other, wrongHost]))
        precondition(cold.receive([connect]))
        precondition(!cold.setReady(true))

        // A link arriving during quit is deferred until a canceled quit makes
        // the host ready again; successful quit does not consume it.
        precondition(!cold.setReady(false))
        precondition(!cold.receive([connect]))
        precondition(!cold.setReady(false))
        precondition(cold.setReady(true))
        precondition(!cold.setReady(true))
        print("HostBridgeURLRouter synthetic cases passed")
    }
}
