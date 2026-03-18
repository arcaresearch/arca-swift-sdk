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
    case aggregationUpdated = "aggregation.updated"
    case midsUpdated = "mids.updated"
    case candleClosed = "candle.closed"
    case candleUpdated = "candle.updated"
    case realmCreated = "realm.created"
    case agentText = "agent.text"
    case agentToolUse = "agent.tool_use"
    case agentPlan = "agent.plan"
    case agentConversationLog = "agent.conversation_log"
    case agentDone = "agent.done"
    case agentStepUpdated = "agent.step_updated"
    case agentExecutionDone = "agent.execution_done"
    case exchangeFill = "exchange.fill"
    case objectValuation = "object.valuation"
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
