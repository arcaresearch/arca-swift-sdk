import Foundation

/// What an exchange arca reports about its own provisioning.
///
/// Creating an exchange arca returns as soon as the object exists, which is
/// before its venue account does; until then, trading calls answer
/// `503 EXCHANGE_PROVISIONING`. ``EventType/exchangeProvisioned`` and
/// ``EventType/exchangeReady`` are how you learn that changed without polling
/// for it, and this is the payload both carry.
public struct ExchangeProvisioning: Codable, Sendable {
    public let objectId: String?
    public let path: String?
    /// The boundary is cosign-armed, so the account exists but cannot trade
    /// until the user co-signs the agent grant. Expect
    /// ``EventType/exchangeReady`` once they do.
    public let cosignRequired: Bool?
    /// The account can actually trade. Always true on
    /// ``EventType/exchangeReady``.
    public let tradable: Bool?
    /// The venue account address, once stamped.
    public let accountAddress: String?
    public let agentWalletId: String?

    public init(
        objectId: String? = nil,
        path: String? = nil,
        cosignRequired: Bool? = nil,
        tradable: Bool? = nil,
        accountAddress: String? = nil,
        agentWalletId: String? = nil
    ) {
        self.objectId = objectId
        self.path = path
        self.cosignRequired = cosignRequired
        self.tradable = tradable
        self.accountAddress = accountAddress
        self.agentWalletId = agentWalletId
    }
}

/// Money observed arriving at a watched deposit address.
///
/// This is chain truth, not ledger truth: nothing here has been credited yet.
/// `amount` is the transfer's value in whole units, and `sweeping` says whether
/// the platform is already moving it into the boundary without further action
/// from the user.
public struct DetectedDeposit: Codable, Sendable {
    public let address: String?
    public let from: String?
    public let amount: String?
    public let txHash: String?
    public let block: UInt64?
    public let boundaryId: String?
    public let sweeping: Bool?

    public init(
        address: String? = nil,
        from: String? = nil,
        amount: String? = nil,
        txHash: String? = nil,
        block: UInt64? = nil,
        boundaryId: String? = nil,
        sweeping: Bool? = nil
    ) {
        self.address = address
        self.from = from
        self.amount = amount
        self.txHash = txHash
        self.block = block
        self.boundaryId = boundaryId
        self.sweeping = sweeping
    }
}
