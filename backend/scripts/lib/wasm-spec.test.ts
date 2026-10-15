// The constructor guard (CT-11a lead decision L-d) and the spec type model. Offline: the WASMs are the Soroswap and
// Aquarius fixtures in contracts/testdata, and minimal modules carrying the merged contracts' real constructor specs.
import { assert, assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Address, scValToNative, xdr } from "@stellar/stellar-sdk";
import {
  compareParams,
  constructorGuard,
  customSections,
  functionNames,
  functionParams,
  param,
  readSpec,
  renderParams,
  renderType,
  T,
  toScVal,
  wasmDeclaring,
  wasmWithSections,
} from "./wasm-spec.ts";

const root = new URL("../../../", import.meta.url).pathname;
const fixture = (name: string) => Deno.readFileSync(`${root}contracts/testdata/${name}`);

Deno.test("reads the contract spec of a real WASM (the Soroswap pair fixture)", () => {
  const wasm = fixture("soroswap_pair.wasm");
  assertEquals(customSections(wasm, "contractspecv0").length, 1);
  const names = functionNames(readSpec(wasm));
  for (const f of ["initialize", "deposit", "withdraw", "token_0", "token_1", "total_supply"]) assert(names.includes(f), f);
  assertEquals(renderParams(functionParams(readSpec(wasm), "initialize")!), "(factory: Address, token_0: Address, token_1: Address)");
  assertEquals(functionParams(readSpec(wasm), "no_such_function"), null);
});

Deno.test("a real WASM whose function matches the builder passes; a deliberately different builder is refused", () => {
  const wasm = fixture("soroswap_pair.wasm");
  const right = [param("factory", T.address), param("token_0", T.address), param("token_1", T.address)];
  assertEquals(constructorGuard(wasm, right, "initialize"), {
    ok: true,
    actual: "(factory: Address, token_0: Address, token_1: Address)",
    differences: [],
  });
  const renamed = [param("factory", T.address), param("token_a", T.address), param("token_1", T.address)];
  const retyped = [param("factory", T.address), param("token_0", T.address), param("token_1", T.option(T.address))];
  const missing = [param("factory", T.address), param("token_0", T.address)];
  const extra = [...right, param("fee", T.u32)];
  const r1 = constructorGuard(wasm, renamed, "initialize");
  assert(!r1.ok);
  assertStringIncludes(r1.differences.join("\n"), "parameter 2 is named token_0 in the WASM, token_a in the builder");
  const r2 = constructorGuard(wasm, retyped, "initialize");
  assert(!r2.ok);
  assertStringIncludes(r2.differences.join("\n"), "the WASM has Address, the builder Option<Address>");
  assertStringIncludes(constructorGuard(wasm, missing, "initialize").differences.join("\n"), "the WASM has an extra parameter 3");
  assertStringIncludes(constructorGuard(wasm, extra, "initialize").differences.join("\n"), "parameter 4 (fee: u32) is missing from the WASM");
});

Deno.test("a real WASM without the constructor a builder expects is refused (the fixtures have none)", () => {
  for (const f of ["soroswap_factory.wasm", "aquarius_router.wasm", "aquarius_token_share.wasm"]) {
    const r = constructorGuard(fixture(f), [param("admin", T.address)]);
    assert(!r.ok, f);
    assertEquals(r.differences, ["the WASM has no __constructor"]);
  }
  const notWasm = constructorGuard(new TextEncoder().encode("not a wasm"), [param("admin", T.address)]);
  assert(!notWasm.ok);
  assertStringIncludes(notWasm.differences[0], "can't read the contract spec");
  const noSpec = constructorGuard(wasmWithSections([["name", new Uint8Array([1, 2, 3])]]), [param("admin", T.address)]);
  assertStringIncludes(noSpec.differences[0], "no contractspecv0 section");
});

// ------------------------------------------------------------------------------------------------ user-defined types

const TtlPolicy = T.struct("TtlPolicy", [["threshold", T.u32], ["extend_to", T.u32]]);
const Mode = T.enumU32("Mode", [["Fail", 0], ["ExhaustBudget", 1], ["BogusSuccess", 2]]);

Deno.test("user-defined types are compared field by field, whatever their declaration order", () => {
  const declared = [param("ttl", TtlPolicy), param("mode", Mode)];
  const wasm = wasmDeclaring("__constructor", declared);
  assertEquals(constructorGuard(wasm, declared).ok, true);
  // The same fields in another order: a named struct is a map sorted by field name, so it encodes the same.
  const reordered = T.struct("TtlPolicy", [["extend_to", T.u32], ["threshold", T.u32]]);
  assertEquals(constructorGuard(wasm, [param("ttl", reordered), param("mode", Mode)]).ok, true);
  // A field of another type, a renamed field, another enum value, another type name: each refused.
  const wide = T.struct("TtlPolicy", [["threshold", T.u64], ["extend_to", T.u32]]);
  assertStringIncludes(constructorGuard(wasm, [param("ttl", wide), param("mode", Mode)]).differences[0], "threshold: u32");
  const renamed = T.struct("TtlPolicy", [["threshold", T.u32], ["extend", T.u32]]);
  assert(!constructorGuard(wasm, [param("ttl", renamed), param("mode", Mode)]).ok);
  const shifted = T.enumU32("Mode", [["Fail", 1], ["ExhaustBudget", 2], ["BogusSuccess", 3]]);
  assert(!constructorGuard(wasm, [param("ttl", TtlPolicy), param("mode", shifted)]).ok);
  const otherName = T.struct("Ttl", [["threshold", T.u32], ["extend_to", T.u32]]);
  assert(!constructorGuard(wasm, [param("ttl", otherName), param("mode", Mode)]).ok);
});

Deno.test("nested user-defined types and unions are resolved from the spec", () => {
  const VenueKind = T.enumU32("VenueKind", [["Soroswap", 0], ["Aquarius", 1], ["HoldOnly", 2], ["QaFail", 3]]);
  const VenueParams = T.struct("VenueParams", [["fee_fraction", T.u32]]);
  const VenueInit = T.struct("VenueInit", [["kind", VenueKind], ["executor", T.address], ["params", VenueParams]]);
  const Ref = T.union("PositionRef", [["Launch", [T.address]], ["Moment", [T.address]]]);
  const declared = [param("venues", T.vec(VenueInit)), param("reference", Ref), param("hash", T.bytesN(32))];
  const params = functionParams(readSpec(wasmDeclaring("__constructor", declared)), "__constructor")!;
  assertEquals(
    renderType(params[0].type, true),
    "Vec<VenueInit { executor: Address, kind: VenueKind enum { Soroswap = 0, Aquarius = 1, HoldOnly = 2, QaFail = 3 }, params: VenueParams { fee_fraction: u32 } }>",
  );
  assertEquals(renderType(params[1].type, true), "PositionRef union { Launch(Address), Moment(Address) }");
  assertEquals(compareParams(params, declared), []);
  const otherKind = T.struct("VenueInit", [["kind", T.u32], ["executor", T.address], ["params", VenueParams]]);
  assertEquals(compareParams(params, [param("venues", T.vec(otherKind)), declared[1], declared[2]]).length, 1);
});

// ------------------------------------------------------------------------------------------------ the merged contracts

// The constructor specs of the merged contracts (main 9354d56): the `__constructor` entry and the user-defined types it
// uses, cut from the contractspecv0 section of each release WASM (cargo build --target wasm32v1-none --release, as
// contracts/build.sh builds them). v2-constructors.test.ts checks the builders against all of them; here exec-soroswap
// shows the guard on a real constructor.
const EXEC_SOROSWAP_CTOR_SPEC = 
  "AAAAAAAAAGNgY2FsbGVyc2AgYXJlIGxhdW5jaHBhZC12MiBhbmQgbW9tZW50cy1ncmFkdWF0b3IsIGJ5IHRoZSBpZHMgdGhlIGRlcGxveSBzY3JpcHQgcHJlY29tcHV0ZXMgKMKnMy40KS4AAAAADV9fY29uc3RydWN0b3IAAAAAAAACAAAAAAAAAAdmYWN0b3J5AAAAABMAAAAAAAAAB2NhbGxlcnMAAAAD6gAAABMAAAAA";

Deno.test("the merged exec-soroswap's real constructor passes with its builder and is refused with a different one", () => {
  const wasm = wasmWithSections([["contractspecv0", Uint8Array.from(Buffer.from(EXEC_SOROSWAP_CTOR_SPEC, "base64"))]]);
  const builder = [param("factory", T.address), param("callers", T.vec(T.address))];
  const ok = constructorGuard(wasm, builder);
  assertEquals(ok, { ok: true, actual: "(factory: Address, callers: Vec<Address>)", differences: [] });
  // A builder that passes the callers as one address, and one that swaps the parameters: both refused.
  const one = constructorGuard(wasm, [param("factory", T.address), param("callers", T.address)]);
  assert(!one.ok);
  assertStringIncludes(one.differences[0], "parameter 2 (callers): the WASM has Vec<Address>, the builder Address");
  const swapped = constructorGuard(wasm, [param("callers", T.vec(T.address)), param("factory", T.address)]);
  assertEquals(swapped.differences.length, 4);
});

const dist = `${root}contracts/dist/dyor_exec_soroswap.wasm`;
const hasDist = (() => {
  try {
    Deno.statSync(dist);
    return true;
  } catch {
    return false;
  }
})();

Deno.test({
  name: "contracts/dist's exec-soroswap passes the guard with its builder (after CT-10 commits dist)",
  ignore: !hasDist,
  fn() {
    const r = constructorGuard(Deno.readFileSync(dist), [param("factory", T.address), param("callers", T.vec(T.address))]);
    assertEquals(r.differences, []);
  },
});

// ------------------------------------------------------------------------------------------------ encoding

Deno.test("values encode as soroban-sdk decodes them", () => {
  const a = "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ";
  const ttl = toScVal(TtlPolicy, { threshold: 120_960, extend_to: 518_400 });
  assertEquals(ttl.switch().name, "scvMap");
  assertEquals(ttl.map()!.map((e) => e.key().sym().toString()), ["extend_to", "threshold"]);
  assertEquals(scValToNative(ttl), { extend_to: 518_400, threshold: 120_960 });
  assertEquals(toScVal(Mode, "Fail").switch().name, "scvU32");
  assertEquals(toScVal(Mode, "BogusSuccess").u32(), 2);
  assertEquals(toScVal(T.option(T.address), null).switch().name, "scvVoid");
  assertEquals(Address.fromScVal(toScVal(T.option(T.address), a)).toString(), a);
  assertEquals(toScVal(T.i128, 100_000_000n).switch().name, "scvI128");
  assertEquals(toScVal(T.u64, 3_600).switch().name, "scvU64");
  assertEquals(toScVal(T.bytesN(32), "ab".repeat(32)).bytes().length, 32);
  assertThrows(() => toScVal(T.bytesN(32), "(dyor_x.wasm absent from dist)"), Error, "bytes (or a hex string)");
  assertThrows(() => toScVal(T.bytesN(32), "ab"), Error, "32 bytes are needed");
  assertThrows(() => toScVal(TtlPolicy, { threshold: 1 }), Error, "extend_to is missing");
  assertThrows(() => toScVal(T.u32, -1), Error, "out of range");
  const union = toScVal(T.union("PositionRef", [["Launch", [T.address]]]), ["Launch", a]);
  assertEquals(union.vec()!.length, 2);
  assertEquals(union.vec()![0].switch(), xdr.ScValType.scvSymbol());
});
