import XCTest
@testable import DyorKit

/// Validates the EIP-712 encoder against the canonical "Ether Mail" example from the specification, whose domain
/// separator and final digest are widely published fixed values.
final class EIP712Tests: XCTestCase {
    private func etherMail() -> EIP712.TypedData {
        let types: [String: [EIP712.Field]] = [
            "EIP712Domain": [
                .init(name: "name", type: "string"),
                .init(name: "version", type: "string"),
                .init(name: "chainId", type: "uint256"),
                .init(name: "verifyingContract", type: "address"),
            ],
            "Person": [
                .init(name: "name", type: "string"),
                .init(name: "wallet", type: "address"),
            ],
            "Mail": [
                .init(name: "from", type: "Person"),
                .init(name: "to", type: "Person"),
                .init(name: "contents", type: "string"),
            ],
        ]
        let domain: [String: Any] = [
            "name": "Ether Mail",
            "version": "1",
            "chainId": 1,
            "verifyingContract": "0xcccccccccccccccccccccccccccccccccccccccc",
        ]
        let message: [String: Any] = [
            "from": ["name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"],
            "to": ["name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"],
            "contents": "Hello, Bob!",
        ]
        return EIP712.TypedData(domain: domain, types: types, primaryType: "Mail", message: message)
    }

    func testEncodeType() throws {
        XCTAssertEqual(try EIP712.encodeType("Mail", etherMail().types), "Mail(Person from,Person to,string contents)Person(string name,address wallet)")
    }

    func testDomainSeparator() throws {
        let separator = try EIP712.hashStruct("EIP712Domain", etherMail().domain, etherMail().types)
        XCTAssertEqual(separator.hexString, "0xf2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f")
    }

    func testMailHashStruct() throws {
        let hash = try EIP712.hashStruct("Mail", etherMail().message, etherMail().types)
        XCTAssertEqual(hash.hexString, "0xc52c0ee5d84264471806290a3f2c4cecfc5490626bf912d01f240d7a274b371e")
    }

    func testDigest() throws {
        let digest = try EIP712.digest(etherMail())
        XCTAssertEqual(digest.hexString, "0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
    }

    func testParseRoundTrip() throws {
        let json: [String: Any] = [
            "domain": etherMail().domain,
            "types": [
                "EIP712Domain": [["name": "name", "type": "string"], ["name": "version", "type": "string"], ["name": "chainId", "type": "uint256"], ["name": "verifyingContract", "type": "address"]],
                "Person": [["name": "name", "type": "string"], ["name": "wallet", "type": "address"]],
                "Mail": [["name": "from", "type": "Person"], ["name": "to", "type": "Person"], ["name": "contents", "type": "string"]],
            ],
            "primaryType": "Mail",
            "message": etherMail().message,
        ]
        let parsed = try EIP712.parse(json)
        XCTAssertEqual(try EIP712.digest(parsed).hexString, "0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
    }
}
