import Foundation

/// Opt-in public quote targets, measured in payload bytes and receive messages per second.
/// Coarse allMids coverage is retained if its unavoidable baseline exceeds the targets.
/// Higher canonical-market priorities win; zero is passive. Arca financial authority is unchanged.
public struct MarketDataBudget: Sendable {
    public let bytesPerSecond: Double
    public let messagesPerSecond: Double
    public let priorities: [String: Int]
    public init(bytesPerSecond: Double, messagesPerSecond: Double, priorities: [String: Int] = [:]) {
        precondition(bytesPerSecond.isFinite && bytesPerSecond >= 0 && messagesPerSecond.isFinite && messagesPerSecond >= 0)
        self.bytesPerSecond = bytesPerSecond; self.messagesPerSecond = messagesPerSecond; self.priorities = priorities
    }
}

struct PublicFeedCost {
    var bytes: Double; var messages: Double
    static func + (lhs: Self, rhs: Self) -> Self { Self(bytes: lhs.bytes + rhs.bytes, messages: lhs.messages + rhs.messages) }
}
/// One bounded sample bucket per active/recent feed. Received frames drive sampling, no polling.
struct PublicFeedCosts {
    private struct Sample { var since: Int; var bytes = 0; var messages = 0 }
    private var samples: [String: Sample] = [:]
    private var estimates: [String: PublicFeedCost] = [:]
    func estimate(_ key: String) -> PublicFeedCost {
        estimates[key] ?? (key.hasPrefix("@") ? PublicFeedCost(bytes: key == "@" ? 5_000 : 650, messages: 0.2) : PublicFeedCost(bytes: 600, messages: 4))
    }
    mutating func retain(_ keys: Set<String>) { samples = samples.filter { keys.contains($0.key) }; estimates = estimates.filter { keys.contains($0.key) } }
    mutating func record(_ key: String, bytes: Int, nowMs: Int) -> Bool {
        var sample = samples[key] ?? Sample(since: nowMs)
        sample.bytes += max(0, bytes); sample.messages += 1
        let elapsed = nowMs - sample.since
        guard elapsed >= 10_000 else { samples[key] = sample; return false }
        let measured = PublicFeedCost(bytes: Double(sample.bytes) * 1_000 / Double(elapsed), messages: Double(sample.messages) * 1_000 / Double(elapsed))
        let old = estimate(key)
        estimates[key] = PublicFeedCost(bytes: max(measured.bytes, old.bytes * 0.8 + measured.bytes * 0.2), messages: max(measured.messages, old.messages * 0.8 + measured.messages * 0.2))
        samples[key] = Sample(since: nowMs)
        return true
    }
}
func venueDex(_ coin: String) -> String { coin.firstIndex(of: ":").map { String(coin[..<$0]) } ?? "" }

/// Deterministic rank under independent network and receive-work budgets; retained selections win ties.
func budgetSubscriptions(mapping: [String: String], budget: MarketDataBudget, costs: PublicFeedCosts,
                         previous: Set<PublicMarketSubscription>, slots: Int) -> Set<PublicMarketSubscription> {
    let groups = Dictionary(grouping: mapping.keys, by: { venueDex(mapping[$0]!) })
    var selected: Set<String> = []
    let previousBbo = Set(previous.filter { $0.interval == nil && $0.dex == nil }.map(\.market))
    func total(_ plan: Set<PublicMarketSubscription>) -> PublicFeedCost {
        plan.reduce(PublicFeedCost(bytes: 0, messages: 0)) { $0 + costs.estimate($1.dex.map { "@" + $0 } ?? $1.market) }
    }
    func fits(_ plan: Set<PublicMarketSubscription>) -> Bool {
        let cost = total(plan)
        return plan.count <= slots && cost.bytes <= budget.bytesPerSecond && cost.messages <= budget.messagesPerSecond
    }
    func plan() -> Set<PublicMarketSubscription> {
        var result: Set<PublicMarketSubscription> = []
        for dex in groups.keys.sorted() {
            let markets = groups[dex]!
            if markets.contains(where: { !selected.contains($0) }) { result.insert(.init(market: "", coin: "", dex: dex)) }
            for market in markets where selected.contains(market) { result.insert(.init(market: market, coin: mapping[market]!)) }
        }
        for dex in groups.keys.sorted() {
            let markets = groups[dex]!
            let remainingCost = markets.filter { !selected.contains($0) }.reduce(PublicFeedCost(bytes: 0, messages: 0)) { $0 + costs.estimate($1) }
            if remainingCost.bytes <= costs.estimate("@" + dex).bytes {
                let candidate = Set(result.filter { $0.dex != dex }).union(markets.map { PublicMarketSubscription(market: $0, coin: mapping[$0]!) })
                if fits(candidate) { result = candidate }
            }
        }
        return result
    }
    let ranked = mapping.keys.sorted {
        let a = budget.priorities[$0] ?? 0, b = budget.priorities[$1] ?? 0
        if a != b { return a > b }
        if previousBbo.contains($0) != previousBbo.contains($1) { return previousBbo.contains($0) }
        return $0 < $1
    }
    var result = plan()
    for market in ranked {
        selected.insert(market)
        let candidate = plan(), cost = total(candidate)
        if candidate.count <= slots && cost.bytes <= budget.bytesPerSecond && cost.messages <= budget.messagesPerSecond { result = candidate }
        else { selected.remove(market) }
    }
    return Set(result.sorted { ($0.dex == nil ? 1 : 0, $0.dex ?? $0.market) < ($1.dex == nil ? 1 : 0, $1.dex ?? $1.market) }.prefix(slots))
}
extension Arca {
    /// Install or remove the optional public quote policy without replacing stream owners.
    public func setMarketDataBudget(_ budget: MarketDataBudget?) async { await ws.setMarketDataBudget(budget) }
}
