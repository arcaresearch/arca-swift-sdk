import XCTest
@testable import ArcaSDK
final class OrderLifecycleTests: XCTestCase {
 private let wire = #"{"intent":{"realmId":"rlm_01h2xcejqtf2nbrexx3vqjhp41","objectId":"account","operationId":"original","leg":"0","venue":"gll-testnet","venueAccountId":"123","market":"gllt:3","requestedSize":"9007199254740993.123456789","orderType":"MARKET","side":"buy","timeInForce":"GTC","executionTimeInForce":"IOC","isTrigger":false,"isMarketTrigger":false,"sizeToMax":false,"reduceOnly":false},"venueOrderId":"3:order","submission":"accepted","working":false,"execution":"partial","terminal":true,"executedSize":"3.123456789","executionQuantityFinal":true,"requestedSizeKnown":true,"remainingSize":"9007199254740990","remainingDisposition":"canceled","accountedSize":"0","accountingComplete":false,"averagePrice":"2000.000000001","averagePriceFinal":false,"recoveryRequired":false}"#
 func testPreservesServerEvidenceAndRequiresExactAccount() throws {
  let v = try JSONDecoder().decode(OrderLifecycle.self, from: Data(wire.utf8))
  try v.validate(realm: "rlm_01h2xcejqtf2nbrexx3vqjhp41", objectId: "account", operationId: "original", leg: 0)
  XCTAssertEqual(v.intent.requestedSize, "9007199254740993.123456789")
  XCTAssertEqual(v.executedSize, "3.123456789")
  XCTAssertEqual(v.remainingSize, "9007199254740990")
  XCTAssertFalse(v.averagePriceFinal); XCTAssertFalse(v.accountingComplete); XCTAssertFalse(v.working)
  XCTAssertThrowsError(try v.validate(realm: "rlm_01h2xcejqtf2nbrexx3vqjhp41", objectId: "foreign", operationId: "original", leg: 0))
  XCTAssertThrowsError(try v.validate(realm: "rlm_01h2xcejqtf2nbrexx3vqjhp41", objectId: "account", operationId: "foreign", leg: 0))
 }
 func testMissingFinalityCannotDecodeAsCompleteOrKnown() {
  let bad = wire.replacingOccurrences(of: #""executionQuantityFinal":true,"#, with: "")
  XCTAssertThrowsError(try JSONDecoder().decode(OrderLifecycle.self, from: Data(bad.utf8)))
 }
}
