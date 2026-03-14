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

// Initialize from a scoped token (minted by your backend)
let arca = try Arca(token: scopedJwt)

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

```swift
// Standard initialization
let arca = try Arca(token: scopedJwt)

// Explicit realm override
let arca = try Arca(token: scopedJwt, realmId: "rlm_01abc")

// Token refresh
await arca.updateToken(newScopedJwt)
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
