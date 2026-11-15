import Foundation

/// The owner's volta-api server. Volta talks to this one server only, so the
/// sign-in screen never asks for an address. The owner chose to publish it;
/// it is reachable only from the owner's tailnet. scripts/privacy-check.sh
/// allows this one line.
enum VoltaServer {
    static let address = "https://george-ubuntu.tail1fdfb0.ts.net:9443"
}
