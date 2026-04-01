# ArcaSDK — Swift SDK for the Arca Platform

A native iOS/macOS client for the Arca platform. Uses Swift structured concurrency (`async/await`), Codable models, and actor-based thread safety. Zero third-party dependencies.

## Requirements

- iOS 15+ / macOS 12+
- Swift 5.9+
- Xcode 15+ (for tests, due to XCTest dependency)

## Installation

### Swift Package Manager

Add the package dependency in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/arcaresearch/arca-swift-sdk.git", from: "0.1.0"),
    // Or use branch-based if version tags aren't published yet:
    // .package(url: "https://github.com/arcaresearch/arca-swift-sdk.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: ["ArcaSDK"]),
]
```

Or in Xcode: **File → Add Package Dependencies → enter the repository URL**. If SPM reports no versions available, use **Branch: main** instead of a version rule.

### Local Development (Monorepo)

When working in the Arca monorepo, add the local package:

```
File → Add Package Dependencies → Add Local... → sdk/swift/
```

## Quick Start

```swift
import ArcaSDK

// Initialize with automatic token refresh (recommended)
let arca = try Arca(
    token: scopedJwt,
    tokenProvider: {
        try await myBackend.getArcaToken()
    }
)

// Ensure a denominated wallet exists
let response = try await arca.ensureDenominatedArca(
    ref: "/wallets/main",
    denomination: "USD"
)

// Deposit funds
let deposit = try await arca.deposit(
    arcaRef: "/wallets/main",
    amount: "1000.00"
)

// Wait for settlement
let completed = try await arca.waitForOperation(
    operationId: deposit.operation.id.rawValue
)

// Check balances
let balances = try await arca.getBalancesByPath(path: "/wallets/main")
```

## Authentication

The Swift SDK is designed for frontend/mobile apps. It authenticates exclusively with **scoped JWT tokens** minted by your backend via `POST /auth/token`. The realm is extracted from the token claims automatically.

### Token Provider (recommended)

Pass a `tokenProvider` closure so the SDK handles refresh automatically:
- **Proactive refresh** — ~30 seconds before token expiry
- **401 retry** — retries the failed request with a fresh token
- **WebSocket** — fetches a fresh token on reconnect

```swift
let arca = try Arca(
    token: scopedJwt,
    tokenProvider: {
        try await myBackend.getArcaToken()
    }
)

// Or provider-only (fetches the first token automatically)
let arca = try await Arca.withTokenProvider {
    try await myBackend.getArcaToken()
}

// Listen for unrecoverable auth failures
await arca.onAuthError { error in
    showSessionExpiredUI()
}
```

### Manual Token Refresh

If you prefer full control, use `updateToken()` to swap the token yourself:

```swift
await arca.updateToken(newScopedJwt)
```

### Configuration

```swift
// Explicit realm override
let arca = try Arca(token: scopedJwt, realmId: "rlm_01abc")
```

No API key auth or admin operations are supported — those are the responsibility of your backend.

## Real-Time Events

Events are delivered via `AsyncStream` — the native Swift concurrency primitive:

```swift
// Connect and subscribe
await arca.ws.connect(channels: [.operations, .balances])

// Iterate over all events
for await event in await arca.ws.events {
    print(event.type, event.entityId ?? "")
}

// Typed convenience streams
for await (operation, event) in await arca.ws.operationEvents() {
    print(operation.type, operation.state)
}
```

## Equity Chart (Historical + Live)

`watchEquityChart` merges historical equity data with a live aggregation stream into a single continuously-updating point array:

```swift
let chart = try await arca.watchEquityChart(
    prefix: "/",
    from: "2026-03-19T00:00:00Z",
    to: "2026-03-20T00:00:00Z",
    points: 200
)

// Iterate over updates — each contains the full point array
for await update in chart.updates {
    renderChart(update.points)
}

// Or read the current snapshot at any time
let currentPoints = chart.chart.value

// Clean up
await chart.stop()
```

The rightmost point reflects the current live equity. When the hour boundary crosses, the live point is promoted to historical and a new one starts — no manual stitching required.

## P&L chart (historical + live)

`watchPnlChart` uses the **same** historical endpoint and live aggregation stream as the equity chart, and subscribes to **operation** events so completed deposits and transfers update cumulative inflows/outflows **on the client** (no extra `getPnlHistory` call per operation). Non-USD flows use `midPrices` from the initial `getPnlHistory` response.

```swift
let chart = try await arca.watchPnlChart(
    prefix: "/",
    from: "2026-03-19T00:00:00Z",
    to: "2026-03-20T00:00:00Z",
    points: 200
)

for await update in chart.updates {
    renderPnlChart(update.points)
    // update.externalFlows — all flows seen so far (historical + live)
}

await chart.stop()
```

`watchPnlChart` acquires the **operations** WebSocket channel for you and releases it in `stop()`.

## Candle chart (historical + live)

`watchCandleChart` merges historical OHLCV candles from the REST API with real-time WebSocket candle events into a single continuously-updating array. It handles subscribe-before-fetch ordering, deduplication, in-place updates for open candles, and automatic gap recovery on reconnection.

Each `CandleChartUpdate.candles` contains the **complete** merged array — it never shrinks. The array grows as new bars form and prepends when `loadMore()` is called.

```swift
let chart = try await arca.watchCandleChart(
    coin: "hl:1:BRENTOIL",
    interval: .oneMinute,
    count: 300  // historical candles to load
)

for await update in chart.updates {
    // update.candles — full sorted array (historical + live), always growing
    // update.latestCandle — the candle that triggered this update
    renderCandleChart(update.candles)
}

await chart.stop()
```

**Important**: Only one `for await` loop should consume a given stream's `updates` at a time. When switching coins or intervals, cancel the previous task and call `stop()` before creating a new stream. In SwiftUI, use `.task(id:)` to get automatic cancellation:

```swift
.task(id: "\(coin):\(interval.rawValue)") {
    guard let chart = try? await arca.watchCandleChart(
        coin: coin, interval: interval
    ) else { return }
    defer { Task { await chart.stop() } }
    for await update in chart.updates {
        self.candles = update.candles
    }
}
```

### Loading a specific range

When the chart viewport changes (zoom, resize, jump to date), call `ensureRange` with the time range you need. The SDK tracks which ranges have already been fetched, loads only the gaps, coalesces overlapping calls, and merges everything into the sorted candle array.

```swift
// Chart zoom-out — tell the SDK what range is now visible:
let result = await chart.ensureRange(newVisibleStart, newVisibleEnd)
// result.loadedCount == 0 means the range was already loaded, or an overlapping
// in-flight ensureRange finished covering it before this call completed.
// result.reachedStart == true means no more history exists before the array start
```

### Loading older candles

For simple backward scrolling, `loadMore` fetches older candles before the current earliest. It accepts an optional count (default 300).

```swift
// In your chart's scroll handler:
let result = await chart.loadMore(200)
if result.reachedStart {
    // No more history available
}
```

For raw candle events without blending, use `watchCandles()` instead.

## Build & Test

```bash
cd sdk/swift

# Build
swift build

# Run tests (requires Xcode for XCTest)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Clean
swift package clean
```

## Architecture

| Component | Role |
|-----------|------|
| `Arca` | Main entry point — realm-scoped, all methods `async throws` |
| `Arca+Objects` | Object CRUD extensions |
| `Arca+Transfers` | Transfer, deposit, withdrawal extensions |
| `Arca+Operations` | Operations, events, deltas, nonce, summary |
| `Arca+Exchange` | Exchange/perps operations |
| `Arca+Aggregation` | Aggregation, P&L, equity history |
| `ArcaClient` (actor) | HTTP client with retry logic and envelope unwrapping |
| `WebSocketManager` (actor) | WebSocket with reconnection and `AsyncStream` delivery |
| `Models/` | All Codable DTOs with phantom-typed `TypedID<Tag>` |

## API Surface

All methods excluded from this SDK (admin/debug utilities like `checkInvariants`, `waitForQuiescence`, `listReconciliationState`, `ArcaAdmin`) are available through the TypeScript SDK or direct API calls from your backend.
