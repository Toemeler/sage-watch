import Foundation
import Network

/// Talks to the WiZ bulbs over the local UDP API (port 38899, JSON, no auth) — the same protocol as
/// wizctl.py in C:\Users\Tom\wiz-local. All bulbs are driven together.
enum WizClient {
    /// the bulbs from wiz-local/bulbs.json (DHCP-reserved IPs)
    static let defaultBulbs = ["192.168.0.148", "192.168.0.71", "192.168.0.219"]
    static var bulbs: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: "wizBulbs") ?? []
        return saved.isEmpty ? defaultBulbs : saved
    }

    /// one request, one reply; nil after the timeout (bulb off the network, or not at home)
    static func send(_ ip: String, method: String, params: [String: Any], timeout: Double = 0.8) async -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else { return nil }
        for _ in 0..<2 {   // UDP is lossy: one retry
            if let r = await once(ip, body, timeout) { return r }
        }
        return nil
    }

    private static func once(_ ip: String, _ body: Data, _ timeout: Double) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: 38899, using: .udp)
            let queue = DispatchQueue(label: "wiz.\(ip)")
            var done = false
            func finish(_ v: [String: Any]?) {
                guard !done else { return }
                done = true; conn.cancel(); cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { s in if case .failed = s { finish(nil) } }
            conn.start(queue: queue)
            conn.send(content: body, completion: .contentProcessed { error in
                if error != nil { finish(nil); return }
                conn.receiveMessage { data, _, _, _ in
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    finish(json?["result"] as? [String: Any] ?? json)
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// state of the lamps: the first bulb that answers sets on/brightness/colour, `count` is how many answered
    static func status() async -> LampLink.State {
        let replies = await withTaskGroup(of: [String: Any]?.self) { g in
            for ip in bulbs { g.addTask { await send(ip, method: "getPilot", params: [:]) } }
            var out: [[String: Any]] = []
            for await r in g { if let r { out.append(r) } }
            return out
        }
        guard let first = replies.first else { return LampLink.State() }
        var s = LampLink.State(pilot: first)
        s.on = replies.contains { $0["state"] as? Bool == true }
        s.count = replies.count
        return s
    }

    /// setPilot on every bulb, then the new state
    static func set(_ params: [String: Any]) async -> LampLink.State {
        await withTaskGroup(of: Void.self) { g in
            for ip in bulbs { g.addTask { _ = await send(ip, method: "setPilot", params: params) } }
        }
        return await status()
    }

    /// answers a watch message
    static func handle(_ message: [String: Any]) async -> [String: Any] {
        switch message[LampLink.commandKey] as? String {
        case LampLink.audio:
            var reply = AudioRoute.current()
            let track = await Spotify.shared.nowPlayingReply(watchHas: message["artURL"] as? String)
            reply.merge(track) { _, new in new }
            return reply
        case LampLink.set:
            return await set(message[LampLink.paramsKey] as? [String: Any] ?? [:]).dictionary
        default:
            return await status().dictionary
        }
    }
}
