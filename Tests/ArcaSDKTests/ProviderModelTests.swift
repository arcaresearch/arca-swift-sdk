import XCTest
@testable import ArcaSDK

final class ProviderModelTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testProviderTypeAndDeltaTypesDecode() throws {
        XCTAssertEqual(try decoder.decode(ArcaObjectType.self, from: Data(#""provider""#.utf8)), .provider)
        XCTAssertEqual(ArcaObjectType.provider.rawValue, "provider")
        XCTAssertEqual(try decoder.decode(DeltaType.self, from: Data(#""provider_change""#.utf8)), .providerChange)
        XCTAssertEqual(try decoder.decode(DeltaType.self, from: Data(#""deposit_link_change""#.utf8)), .depositLinkChange)
    }

    /// Object detail of a provider object: the provider section, an unobserved
    /// wallet (observation null, never zero) and a link whose requested,
    /// observed and operation state are separate fields.
    func testObjectDetailWithProviderAndDepositLinksDecodes() throws {
        let json = #"""
        {"object":{"id":"obj_p","realmId":"rlm_1","path":"/users/a/privy","type":"provider","status":"active","systemOwned":false,"createdAt":"t","updatedAt":"t"},
         "operations":[],"events":[],"deltas":[],"balances":[],
         "provider":{"objectId":"obj_p","path":"/users/a/privy",
           "state":{"schema":1,"provider":"privy","subject":"did:privy:a","connection":{"status":"verified","checkedAt":"t","evidence":{"kind":"privy_identity_token","issuedAt":"t","expiresAt":"t","keyId":"k1"}}},
           "wallets":[{"walletId":"pwl_a","chainType":"ethereum","address":"0xA","role":"primary_deposit","verification":{"status":"verified","verifiedAt":"t"},"controls":[{"target":"pwl_b","relation":"signer_for"}],"observation":null}]},
         "depositLinks":[{"id":"dlk_1","realmId":"rlm_1",
           "source":{"objectId":"obj_p","path":"/users/a/privy","walletId":"pwl_a","address":"0xA"},
           "destination":{"objectId":"obj_c","path":"/users/a/cash","boundaryId":"0xb","account":{"kernel":"0xk","venue":"0xv","localId":"0xl"}},
           "chainId":"999","token":"0xt","adapter":{"address":"0xad","kind":"cash_autodeposit_v1"},
           "requested":{"state":"revoked","at":"t","revokeRequestedAt":"t"},"lifetime":"until_revoked_or_invalidated",
           "consent":null,"limits":null,
           "observed":{"status":"active","routeId":"0xr","matchesDestination":true,"health":"live","asOf":{"block":46200000,"hash":"0xh"}},
           "operations":{"revokeOperationId":"opr_1"},"progress":"revoke_in_flight","createdAt":"t","updatedAt":"t"}]}
        """#
        let detail = try decoder.decode(ArcaObjectDetailResponse.self, from: Data(json.utf8))
        XCTAssertEqual(detail.object.type, .provider)
        let provider = try XCTUnwrap(detail.provider)
        XCTAssertEqual(provider.state.subject, "did:privy:a")
        XCTAssertNil(provider.wallets[0].observation)
        XCTAssertEqual(provider.wallets[0].controls.first?.relation, "signer_for")
        let link = try XCTUnwrap(detail.depositLinks?.first)
        XCTAssertEqual(link.requested.state, "revoked")
        XCTAssertEqual(link.observed.status, "active")
        XCTAssertEqual(link.operations.revokeOperationId, "opr_1")
        XCTAssertEqual(link.progress, "revoke_in_flight")
        XCTAssertNil(link.consent)
    }

    func testObjectDetailWithoutProviderSectionsDecodes() throws {
        let json = #"{"object":{"id":"obj_w","realmId":"rlm_1","path":"/w","type":"denominated","status":"active","systemOwned":false,"createdAt":"t","updatedAt":"t"},"operations":[],"events":[],"deltas":[],"balances":[]}"#
        let detail = try decoder.decode(ArcaObjectDetailResponse.self, from: Data(json.utf8))
        XCTAssertNil(detail.provider)
        XCTAssertNil(detail.depositLinks)
    }
}
