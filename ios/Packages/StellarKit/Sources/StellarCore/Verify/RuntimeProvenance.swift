import Foundation

/// Which WASM a contract created at runtime counts by (DESIGN-stellar-contracts-v2 §20.1), read from its instance
/// ledger entry: the hash LiteClient hands TxVerifier as `runtimeContracts` / `verifiedLaunchTokens`.
///
/// A pinned runtime WASM alone proves nothing: anyone can deploy an instance of an uploaded WASM, with constructor
/// arguments of their choosing (launch-token-v2's `sharing_quote`, for one, names a contract whose code its `claim`
/// runs). So an instance of a pinned v2 runtime WASM counts only when the pinned singleton created it: launch-token-v2's
/// stored `Launchpad` is the pinned launchpad-v2, a Moment NFT's or coin's stored `Minter` the pinned moments-v2. And
/// the entry must be the one asked for: its contract address is the contract read. verify.ts `runtimeWasmHashOf` is
/// the same check (shared vectors: Tests/StellarCoreTests/Vectors/runtime.json).
public enum RuntimeProvenance {
    /// The WASM hash (lowercase hex) `contract` counts by, from its instance entry (`LedgerEntryData` XDR, as
    /// getLedgerEntries returns it). Nil for a Stellar Asset Contract or any other entry, for an entry of another
    /// contract, and for an instance of a pinned v2 runtime WASM whose stored creator isn't the pinned singleton. Any
    /// other WASM's hash is returned as read (PlanRunner.runtimeContracts keeps only pinned ones).
    public static func wasmHash(ofInstance bytes: [UInt8], contract: String, pinned: PinnedContracts) throws -> String? {
        var r = XDRReader(bytes)
        guard try r.int32() == 6 else { return nil } // CONTRACT_DATA
        _ = try r.int32() // ext
        guard case let .contract(id) = try XDRDecode.scAddress(&r), id == contract else { return nil }
        guard try r.int32() == 20 else { return nil } // key: SCV_LEDGER_KEY_CONTRACT_INSTANCE
        _ = try r.int32() // durability
        guard try r.int32() == 19 else { return nil } // SCV_CONTRACT_INSTANCE
        guard try r.int32() == 0 else { return nil } // CONTRACT_EXECUTABLE_WASM (1 = Stellar asset)
        let hash = hex(try r.fixed(32))
        guard let (key, creator) = creatorKey(of: hash, pinned: pinned) else { return hash }
        // Read only for a pinned v2 runtime WASM: ScContractInstance.storage, an optional ScMap.
        let storage = try r.optional { r in
            try r.array(max: 1_000, "instance storage") { r in (try XDRDecode.scVal(&r), try XDRDecode.scVal(&r)) }
        } ?? []
        // A unit variant of a #[contracttype] enum is stored as a one-symbol vector.
        let stored = storage.first { $0.0 == .vec([.symbol(key)]) }?.1
        guard let creator, case let .address(.contract(storedCreator))? = stored, storedCreator == creator else { return nil }
        return hash
    }

    /// For a pinned v2 runtime WASM, the instance-storage key that names its creator and the pinned contract it must
    /// name (nil when that singleton isn't pinned, so nothing counts); nil for any other WASM.
    static func creatorKey(of hash: String, pinned: PinnedContracts) -> (key: String, creator: String?)? {
        let runtime = pinned.runtimeWasmHashes.mapValues { $0.lowercased() }
        guard !hash.isEmpty else { return nil }
        if runtime["launchTokenV2"] == hash { return ("Launchpad", pinned.contracts("launchpadV2").first) }
        if runtime["momentNft"] == hash || runtime["momentCoin"] == hash { return ("Minter", pinned.contracts("momentsV2").first) }
        return nil
    }
}
