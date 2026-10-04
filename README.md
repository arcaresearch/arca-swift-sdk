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

// Ensure a denominated wallet exists (USD-only today)
let response = try await arca.ensureDenominatedArca(
    ref: "/wallets/main"
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

## Execution receipts and recorded prices

`OrderHandle.executionReceipt(...)` confirms terminal execution from account-scoped
pushes and the original operation. It preserves requested/executed/remainder quantities
for partially filled IOC orders even when venue history rewrites the order size.
Execution proof is independent of complete order metadata or journal settlement.
A venue aggregate price is provisional and may be absent.

Use the receipt's account-scoped `watchFills` merged list to refine the price:

```swift
let receipt = try await order.executionReceipt(timeoutSeconds: 30)
let fills = try await arca.watchFills(objectId: receipt.objectId)
let refined = receipt.refined(using: fills.fills.value)
// Observe fills.fills changes and refine again; stop the owned watch when done.
await fills.stop()
```

Refinement requires recorded fills whose `orderOperationId` and `orderId` match
this receipt and whose deduplicated quantities equal its executed quantity.
`Fill.operationId` identifies the recording operation; previews cannot finalize a
price. Incomplete, conflicting, or foreign evidence leaves the receipt unchanged.
A complete result sets `averagePriceFinal`, `fillsComplete`, and
`averagePriceSource = "ledger_vwap"`; its VWAP is rounded to 18 fractional digits,
half-even. Original execution and remainder fields never change.

Fill events use the exact account `entityPath` when present; `entityId` may be a
fill ID. Object-ID matching is a fallback only for events without a path. Use
v2.3.1 or later for this account-scope correction.

`watchFills` installs listeners before subscribing, merges by stable `fillId`
(falling back to row `id`), and traverses history cursors up to 1,000 pages.
Its `limit` is the page size. Startup and actual gap/reconnect recovery use a fresh
watch acknowledgement plus a paginated snapshot, with at most three attempts per
recovery. Failed recovery remains `reconnecting` until a later gap/reconnect;
healthy watches perform no periodic history reads. Stop the watch on account
change. A fill has no embedded account ID, so callers must retain the account
scope of the watch used for refinement.

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

### Wallet Account (V9 cash)

One read and one stream per owner-facing wallet, composed by Arca from durable
records with no chain call. The stream delivers the *complete* Wallet Account on
connect and after every change (at most one per 250 ms), resumes with
`Last-Event-ID` and 1 s → 30 s backoff after a disconnect, and throws only when
the server refuses the connection.

```swift
let wallet = try await arca.walletAccount(boundaryId: boundaryId)

for try await wallet in arca.walletAccountEvents(boundaryId: boundaryId) {
    render(wallet) // wallet.typedWalletState, wallet.balances, wallet.autoDeposit, wallet.operations
}
```

### Socket rotation

Infrastructure in front of the API caps how long any WebSocket may stay open, and for a socket that cap is a maximum lifetime, not an idle timeout — a busy connection is severed on schedule. Reaching it costs an unplanned reconnect (backoff, TCP, TLS, auth, resubscribe), during which a price display holds its last value and looks frozen. The SDK replaces the socket before the cap: a second connection authenticates and re-issues every subscription while the current one keeps streaming, and only takes over once the server confirms the new subscriptions are live. Nothing is missed, no status change is emitted, and a failure anywhere leaves the original socket serving.

`connectionLifetime` on `Arca.init`, `Arca.withTokenProvider` or `WebSocketManager.init` overrides the default of 50 minutes, and the server's reported lifetime is preferred over it when present, so the schedule retunes without an SDK release. `0` disables rotation and outranks both — the socket then runs until something else ends it, which on a fleet that enforces a cap means an unplanned reconnect.

```swift
// Fires when delivery has moved to a new socket.
let id = await arca.ws.onRotated { print("socket replaced") }
await arca.ws.removeRotatedHandler(id)

for await _ in await arca.ws.rotatedStream { print("socket replaced") }

// Trigger one on demand; false when there is no healthy socket to hand off
// from, or a rotation is already under way.
let started = await arca.ws.rotateConnection()
```

A rotation is **not** a reconnect — don't refetch history or run gap recovery from `onRotated`. Rotations are routine, so a refetch there becomes steady background load on every connected client. The hook exists for state the server holds per-connection and so cannot survive the swap; the SDK re-issues mids, candles, open interest, path watches, and chart-history watches itself, and uses the hook internally to re-create standalone aggregation watches.

## Equity Chart (Historical + Live)

`watchEquityChart` merges historical equity data with a live aggregation stream into a single continuously-updating point array:

```swift
let chart = try await arca.watchEquityChart(
    prefix: "/",
    from: "2026-03-19T00:00:00Z",
    to: "2026-03-20T00:00:00Z",
    points: 1000
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

The chart self-heals across iOS / macOS app suspension. On every successful `WebSocketManager.onAuthenticated`, `onResume` (foreground after a hidden period), wall-clock boundary advance with no aggregation activity, and multi-bucket time jump detected on the agg-tick path, the stream refetches the visible window from the server. When the requested `to` is within ~60s of construction time, both `from` and `to` slide forward on every refresh so the displayed window stays anchored to "now" — no manual reload needed when the user returns to a backgrounded app. `onResume` is wired to `UIApplication.willEnterForegroundNotification` (iOS / tvOS / visionOS) and `NSApplication.willBecomeActiveNotification` (macOS); on Linux/server-side Swift it's a no-op since there's no foreground/background concept.

## P&L chart (historical + live)

`watchPnlChart` uses the **same** historical endpoint and live aggregation stream as the equity chart, and subscribes to **operation** events so completed deposits and transfers update cumulative inflows/outflows **on the client** (no extra `getPnlHistory` call per operation). Non-USD flows use `midPrices` from the initial `getPnlHistory` response.

```swift
let chart = try await arca.watchPnlChart(
    prefix: "/",
    from: "2026-03-19T00:00:00Z",
    to: "2026-03-20T00:00:00Z",
    points: 1000
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
    market: "hl:1:BRENTOIL",
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
.task(id: "\(market):\(interval.rawValue)") {
    guard let chart = try? await arca.watchCandleChart(
        market: market, interval: interval
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
| `WebSocketManager` (actor) | WebSocket with reconnection, gapless rotation, and `AsyncStream` delivery |
| `Models/` | All Codable DTOs with phantom-typed `TypedID<Tag>` |

## API Surface

All methods excluded from this SDK (admin/debug utilities like `checkInvariants`, `waitForQuiescence`, `listReconciliationState`, `ArcaAdmin`) are available through the TypeScript SDK or direct API calls from your backend.


## Account capabilities and reduction sizing

Use getExchangeCapabilities for account-authoritative optional controls. Use normalizedReductionSize with canonical market, exact size and fraction; it reads market lot precision and returns an exact rounded-down decimal, rejecting missing metadata and invalid/sub-lot values. Never infer precision or feature support from a venue prefix.
## Operation wait recovery

`waitForOperation` listens before acquiring its subscription. Startup and actual
stream gaps, reauthentication, or sparse operation notifications request a fresh,
correlated acknowledgement before reading the operation. A failed acknowledgement
or read gets at most three attempts per recovery; a healthy pending operation
stays on the stream without periodic reads. A terminal push can complete during
acknowledgement or snapshot recovery. Timeout stops the wait and preserves the
original operation identity; it never submits a replacement operation.

Terminal operations in the initial or buffered subscription snapshot resolve the wait before any HTTP read, including typed failed/expired results. Socket rotation requests fresh operation evidence on the replacement connection; its pong only establishes transport readiness. Stale snapshot request IDs and unrelated operation IDs cannot settle the wait.
Verified snapshot operations are shared with all live waiters, including results buffered while another caller refreshes the same root watch; each waiter still accepts only its original operation ID.

### Optional direct public market data (2.11.0)

The Swift and Kotlin SDKs keep **Arca as the default**. Opting into Hyperliquid
changes public midpoint prices and the current open candle only. Choose the
venue network explicitly; the SDK never infers it from a realm or custody chain.
Both sources feed the same SDK price stream, including client-priced equity,
P&L, valuation and sizing. Server-priced states, allocation quotes, limits,
execution and recorded fills retain their existing authority.

Direct quotes use **BBO midpoint, not Hyperliquid mark or last trade**. Raw
precision is preserved; round only for presentation. The adapter reads exact
`Market.venueSymbol` metadata for a canonical market ID. Missing or ambiguous
metadata, non-Hyperliquid markets, excess interests and 15-second candles stay
on Arca. `watchPrices()` without a market list does not subscribe the entire
venue directly. Pass the visible markets and replace them with `setMarkets` as
visibility changes. Exchange-state watches add their held markets automatically;
max-order-size watches add their selected market. Always stop unused watches.

One public socket per SDK instance has at most 64 subscriptions (price interests
first, then candles; each group sorted by canonical ID). It uses a separate
unauthenticated client, JSON heartbeats, bounded frames, paced subscription
changes and reconnect backoff. Background/disconnect and zero interests close
it. These are per-instance limits, not guarantees against shared-IP venue limits.

Direct price changes are merged before financial fan-out: first change immediate,
then at most one latest batch per 100 ms, with one pending value per market and
no idle timer. Quantity-only BBO changes do not trigger valuation. Do not add a
second 100 ms throttle downstream when consuming this path; retain per-field UI
deduplication and separate slower chart-history work. The scheduler bounds added
SDK delay under normal execution, not OS stalls or venue update cadence.

Arca stays subscribed. Each market uses Arca until its first valid direct frame;
on source failure it resumes from the next arriving Arca frame, never an emitted
cached fallback. Reconnection messages are generation-fenced. The existing Arca
wire payload lacks the venue event timestamp, so fallback event-time ordering
and exact end-to-end age cannot be guaranteed. `marketDataSourceStatus` reports
preference, requested direct subscription count, markets with direct frames, and
the latest source error; readiness is not a latency or completeness guarantee.

Direct candles update only the current open bucket. Arca finalized bars and
history/gap recovery remain authoritative; a closed bar cannot be overwritten by
a late direct open frame. No price or candle polling fallback is introduced.
Switch preference back to Arca at runtime without replacing watches; a
configuration-generation guard prevents a late metadata read from re-enabling
an earlier preference.

```swift
try await arca.setMarketDataPreference(.hyperliquid, network: .mainnet)
let prices = try await arca.watchPrices(markets: ["hl:0:BTC", "hl:0:ETH"])
await prices.setMarkets(["hl:0:BTC"])
let source = await arca.marketDataSourceStatus
// Reversible, including existing account/valuation watches:
try await arca.setMarketDataPreference(.arca)
await prices.stop()
```

## Market data diagnostics (2.12.0)

`watchMarketDataDiagnostics()` observes a conflated cumulative `MarketDataDiagnostics`
snapshot: Swift returns an AsyncStream (await it); Kotlin returns a StateFlow.
`marketDataDiagnostics` reads the current snapshot (await in Swift). Observation
adds no socket, subscription or polling timer. Updates accompany traffic at most
once a second plus source/interest/connection transitions. Cancel observation to
release it. Use foreground-window deltas, not number of diagnostic callbacks.

Fields: elapsedMs, preference, requestedPriceMarkets, directSubscriptions,
arcaServingMarkets/hyperliquidServingMarkets (last routed quote source),
arcaPriceValues/hyperliquidPriceValues, arcaCandleFrames/hyperliquidCandleFrames,
hyperliquidFailures/hyperliquidRecoveries/hyperliquidRecoveryMs,
arcaConnected/arcaDisconnects, arcaPayloadBytes/hyperliquidPayloadBytes, firstPriceMs.
Counters last for one SDK client and include reconnects. Deliberate disconnects
can increment Arca disconnects; split lifecycle windows. Intentional suspension
cancels a pending direct-recovery duration. All bytes are incoming application
payloads, excluding framing/TLS; Arca's count includes its shared account socket.
The first price delay starts at socket-manager creation and concerns the first
routed interested price. It is not venue latency. Quiet prices are not failures,
no exchange timestamp is invented, and Arca still owns finalized candles.
