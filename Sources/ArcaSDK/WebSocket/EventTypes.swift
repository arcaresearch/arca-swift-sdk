import Foundation

/// Event types emitted by the Arca WebSocket stream.
public enum EventType: String, Sendable {
    case operationCreated = "operation.created"
    case operationUpdated = "operation.updated"
    case eventCreated = "event.created"
    case objectCreated = "object.created"
    case objectUpdated = "object.updated"
    case objectDeleted = "object.deleted"
    case balanceUpdated = "balance.updated"
    case exchangeUpdated = "exchange.updated"
    /// The exchange arca's venue account exists and its metadata is stamped, so
    /// it stops answering `503 EXCHANGE_PROVISIONING`.
    ///
    /// This does not always mean it can trade: on a cosign-armed boundary the
    /// trading agent still needs the user's co-signature, which
    /// ``ExchangeProvisioning/cosignRequired`` reports and ``exchangeReady``
    /// marks.
    case exchangeProvisioned = "exchange.provisioned"
    /// The trading agent is registered on chain and the account can trade.
    ///
    /// On an unarmed boundary this follows ``exchangeProvisioned`` immediately.
    /// On an armed one it waits for the user's co-signed agent grant, which may
    /// be minutes or days — treat the gap as waiting on the user, not a stall.
    case exchangeReady = "exchange.ready"
    /// Money seen arriving at a watched deposit address, before it has been
    /// swept into the boundary and become balance. ``balanceUpdated`` is still
    /// what says the funds landed; this is the honest earlier signal that they
    /// are on their way.
    case depositDetected = "deposit.detected"
    case aggregationUpdated = "aggregation.updated"
    case midsUpdated = "mids.updated"
    case candleClosed = "candle.closed"
    case candleUpdated = "candle.updated"
    case oiUpdated = "oi.updated"
    case tradeExecuted = "trade.executed"
    case tradesBatch = "trades.batch"
    case realmCreated = "realm.created"
    case agentText = "agent.text"
    case agentToolUse = "agent.tool_use"
    case agentPlan = "agent.plan"
    case agentConversationLog = "agent.conversation_log"
    case agentDone = "agent.done"
    case agentStepUpdated = "agent.step_updated"
    case agentExecutionDone = "agent.execution_done"
    /// Phase 1 of two-phase fill delivery: instant, incomplete venue-level fill
    /// echo. `fillRecorded` (Phase 2) follows with the authoritative record;
    /// merge the pair by `correlationId`.
    case fillPreviewed = "fill.previewed"
    case fillRecorded = "fill.recorded"
    case exchangeFunding = "exchange.funding"
    case objectValuation = "object.valuation"
    case chartSnapshotUpdated = "chart.snapshot.updated"
    case twapStarted = "twap.started"
    case twapProgress = "twap.progress"
    case twapCompleted = "twap.completed"
    case twapCancelled = "twap.cancelled"
    case twapFailed = "twap.failed"
}

/// Channel groups for WebSocket subscriptions.
public enum Channel: String, Sendable, CaseIterable {
    case operations
    case balances
    case exchange
    case objects
    case events
    case aggregation
    case agent
}

/// WebSocket connection status.
public enum ConnectionStatus: Sendable {
    case connecting
    case connected
    case disconnected
}
