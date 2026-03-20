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
