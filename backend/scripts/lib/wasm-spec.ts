// Contract specs (the WASM's `contractspecv0` custom section) for the v2 deploy kit: the constructor guard (CT-11a
// lead decision L-d), the type model the constructor builders declare their parameters in, and the encoding of those
// parameters to ScVals (docs/DESIGN-stellar-contracts-v2.md §3.4, §17).
//
// The guard reads the constructor's parameter names and types from the WASM itself and compares them with what
// lib/v2-constructors.ts builds, user-defined types (structs, enums, unions) compared field by field, so a contract
// whose constructor drifted from the builder is refused before anything is deployed.
import { Buffer } from "node:buffer";
import { Address, contract, nativeToScVal, xdr } from "@stellar/stellar-sdk";

// ------------------------------------------------------------------------------------------------ the type model

export type PrimName =
  | "Val"
  | "bool"
  | "()"
  | "Error"
  | "u32"
  | "i32"
  | "u64"
  | "i64"
  | "Timepoint"
  | "Duration"
  | "u128"
  | "i128"
  | "U256"
  | "I256"
  | "Bytes"
  | "String"
  | "Symbol"
  | "Address"
  | "MuxedAddress";

/** A spec type. A `udt` carries its definition when it is known (always, for the builders' own declarations). */
export type SpecType =
  | { kind: "prim"; name: PrimName }
  | { kind: "bytesN"; n: number }
  | { kind: "option"; value: SpecType }
  | { kind: "vec"; element: SpecType }
  | { kind: "map"; key: SpecType; value: SpecType }
  | { kind: "tuple"; items: SpecType[] }
  | { kind: "result"; ok: SpecType; error: SpecType }
  | { kind: "udt"; name: string; def: UdtDef | null };

export type UdtDef =
  | { kind: "struct"; fields: { name: string; type: SpecType }[] }
  | { kind: "enum"; cases: { name: string; value: number }[] }
  | { kind: "union"; cases: { name: string; types: SpecType[] }[] }
  | { kind: "error"; cases: { name: string; value: number }[] };

export interface Param {
  name: string;
  type: SpecType;
}

const prim = (name: PrimName): SpecType => ({ kind: "prim", name });

/** Builders for the declarations in lib/v2-constructors.ts. */
export const T = {
  address: prim("Address"),
  bool: prim("bool"),
  u32: prim("u32"),
  i32: prim("i32"),
  u64: prim("u64"),
  i64: prim("i64"),
  u128: prim("u128"),
  i128: prim("i128"),
  string: prim("String"),
  symbol: prim("Symbol"),
  bytes: prim("Bytes"),
  bytesN: (n: number): SpecType => ({ kind: "bytesN", n }),
  option: (value: SpecType): SpecType => ({ kind: "option", value }),
  vec: (element: SpecType): SpecType => ({ kind: "vec", element }),
  tuple: (...items: SpecType[]): SpecType => ({ kind: "tuple", items }),
  /** A `#[contracttype] struct`; fields in declaration order. */
  struct: (name: string, fields: [string, SpecType][]): SpecType => ({
    kind: "udt",
    name,
    def: { kind: "struct", fields: fields.map(([n, t]) => ({ name: n, type: t })) },
  }),
  /** A `#[contracttype] #[repr(u32)] enum` with explicit values. */
  enumU32: (name: string, cases: [string, number][]): SpecType => ({
    kind: "udt",
    name,
    def: { kind: "enum", cases: cases.map(([n, v]) => ({ name: n, value: v })) },
  }),
  /** A `#[contracttype] enum` with data (encoded as `[Symbol(case), ...values]`). */
  union: (name: string, cases: [string, SpecType[]][]): SpecType => ({
    kind: "udt",
    name,
    def: { kind: "union", cases: cases.map(([n, ts]) => ({ name: n, types: ts })) },
  }),
};

export const param = (name: string, type: SpecType): Param => ({ name, type });

// ------------------------------------------------------------------------------------------------ rendering

/** Rust-like rendering. `deep` expands user-defined types (sorted, so declaration order never matters). */
export function renderType(t: SpecType, deep = false, seen: Set<string> = new Set()): string {
  switch (t.kind) {
    case "prim":
      return t.name;
    case "bytesN":
      return `BytesN<${t.n}>`;
    case "option":
      return `Option<${renderType(t.value, deep, seen)}>`;
    case "vec":
      return `Vec<${renderType(t.element, deep, seen)}>`;
    case "map":
      return `Map<${renderType(t.key, deep, seen)}, ${renderType(t.value, deep, seen)}>`;
    case "tuple":
      return `(${t.items.map((i) => renderType(i, deep, seen)).join(", ")})`;
    case "result":
      return `Result<${renderType(t.ok, deep, seen)}, ${renderType(t.error, deep, seen)}>`;
    case "udt": {
      if (!deep) return t.name;
      if (!t.def) return `${t.name} {?}`;
      if (seen.has(t.name)) return t.name;
      const inner = new Set(seen).add(t.name);
      return `${t.name} ${renderDef(t.def, inner)}`;
    }
  }
}

function renderDef(d: UdtDef, seen: Set<string>): string {
  switch (d.kind) {
    case "struct": {
      // A tuple struct ("0", "1", …) encodes as a vector, so its order matters; a named struct encodes as a map
      // sorted by field name, so its declaration order doesn't.
      const tuple = d.fields.every((f, i) => f.name === String(i));
      const fields = tuple ? d.fields : [...d.fields].sort((a, b) => cmp(a.name, b.name));
      return `{ ${fields.map((f) => `${f.name}: ${renderType(f.type, true, seen)}`).join(", ")} }`;
    }
    case "enum":
    case "error": {
      const cases = [...d.cases].sort((a, b) => a.value - b.value || cmp(a.name, b.name));
      return `${d.kind} { ${cases.map((c) => `${c.name} = ${c.value}`).join(", ")} }`;
    }
    case "union": {
      const cases = [...d.cases].sort((a, b) => cmp(a.name, b.name));
      return `union { ${
        cases.map((c) => c.types.length ? `${c.name}(${c.types.map((x) => renderType(x, true, seen)).join(", ")})` : c.name)
          .join(", ")
      } }`;
    }
  }
}

const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

export function renderParams(params: Param[]): string {
  return `(${params.map((p) => `${p.name}: ${renderType(p.type)}`).join(", ")})`;
}

// ------------------------------------------------------------------------------------------------ reading a WASM

/** The payloads of every custom section called `name`, in file order. Throws on anything that isn't a WASM module. */
export function customSections(wasm: Uint8Array, name: string): Uint8Array[] {
  const bytes = wasm;
  let at = 0;
  const need = (n: number) => {
    if (at + n > bytes.length) throw new Error("not a WASM module: truncated");
  };
  const leb = (): number => {
    let value = 0;
    let shift = 0;
    for (;;) {
      need(1);
      const b = bytes[at++];
      value += (b & 0x7f) * 2 ** shift;
      if ((b & 0x80) === 0) return value;
      shift += 7;
      if (shift > 35) throw new Error("not a WASM module: bad length");
    }
  };
  need(8);
  const magic = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  if (!magic.every((b, i) => bytes[i] === b)) throw new Error("not a WASM module (magic or version)");
  at = 8;
  const out: Uint8Array[] = [];
  const decoder = new TextDecoder("utf-8", { fatal: true });
  while (at < bytes.length) {
    const id = bytes[at++];
    const size = leb();
    need(size);
    const end = at + size;
    if (id === 0) {
      const nameLen = leb();
      if (at + nameLen > end) throw new Error("not a WASM module: bad custom section");
      let sectionName = "";
      try {
        sectionName = decoder.decode(bytes.subarray(at, at + nameLen));
      } catch {
        sectionName = "";
      }
      at += nameLen;
      if (sectionName === name) out.push(bytes.slice(at, end));
    }
    at = end;
  }
  return out;
}

/** Every spec entry of the WASM (all `contractspecv0` sections, in order). Throws when it has none. */
export function readSpec(wasm: Uint8Array): xdr.ScSpecEntry[] {
  const sections = customSections(wasm, "contractspecv0");
  if (sections.length === 0) throw new Error("the WASM has no contractspecv0 section");
  const all = Buffer.concat(sections.map((s) => Buffer.from(s)));
  return new contract.Spec(all).entries;
}

const text = (v: string | Buffer) => (typeof v === "string" ? v : Buffer.from(v).toString("utf8"));

/** The UDT definitions of a spec, by name. */
export function udtDefinitions(entries: xdr.ScSpecEntry[]): Map<string, xdr.ScSpecEntry> {
  const out = new Map<string, xdr.ScSpecEntry>();
  for (const e of entries) {
    const k = e.switch().name;
    if (k === "scSpecEntryUdtStructV0") out.set(text(e.udtStructV0().name()), e);
    else if (k === "scSpecEntryUdtUnionV0") out.set(text(e.udtUnionV0().name()), e);
    else if (k === "scSpecEntryUdtEnumV0") out.set(text(e.udtEnumV0().name()), e);
    else if (k === "scSpecEntryUdtErrorEnumV0") out.set(text(e.udtErrorEnumV0().name()), e);
  }
  return out;
}

const PRIMS: Record<string, PrimName> = {
  scSpecTypeVal: "Val",
  scSpecTypeBool: "bool",
  scSpecTypeVoid: "()",
  scSpecTypeError: "Error",
  scSpecTypeU32: "u32",
  scSpecTypeI32: "i32",
  scSpecTypeU64: "u64",
  scSpecTypeI64: "i64",
  scSpecTypeTimepoint: "Timepoint",
  scSpecTypeDuration: "Duration",
  scSpecTypeU128: "u128",
  scSpecTypeI128: "i128",
  scSpecTypeU256: "U256",
  scSpecTypeI256: "I256",
  scSpecTypeBytes: "Bytes",
  scSpecTypeString: "String",
  scSpecTypeSymbol: "Symbol",
  scSpecTypeAddress: "Address",
  scSpecTypeMuxedAddress: "MuxedAddress",
};

/** Converts a spec type to the model, resolving UDTs through `udts` (a UDT missing from the spec has `def: null`). */
export function fromSpecType(
  t: xdr.ScSpecTypeDef,
  udts: Map<string, xdr.ScSpecEntry>,
  resolving: Set<string> = new Set(),
): SpecType {
  const k = t.switch().name;
  if (PRIMS[k]) return prim(PRIMS[k]);
  switch (k) {
    case "scSpecTypeBytesN":
      return { kind: "bytesN", n: t.bytesN().n() };
    case "scSpecTypeOption":
      return { kind: "option", value: fromSpecType(t.option().valueType(), udts, resolving) };
    case "scSpecTypeVec":
      return { kind: "vec", element: fromSpecType(t.vec().elementType(), udts, resolving) };
    case "scSpecTypeMap":
      return {
        kind: "map",
        key: fromSpecType(t.map().keyType(), udts, resolving),
        value: fromSpecType(t.map().valueType(), udts, resolving),
      };
    case "scSpecTypeTuple":
      return { kind: "tuple", items: t.tuple().valueTypes().map((x) => fromSpecType(x, udts, resolving)) };
    case "scSpecTypeResult":
      return {
        kind: "result",
        ok: fromSpecType(t.result().okType(), udts, resolving),
        error: fromSpecType(t.result().errorType(), udts, resolving),
      };
    case "scSpecTypeUdt": {
      const name = text(t.udt().name());
      const entry = udts.get(name);
      if (!entry || resolving.has(name)) return { kind: "udt", name, def: null };
      const inner = new Set(resolving).add(name);
      return { kind: "udt", name, def: udtDef(entry, udts, inner) };
    }
  }
  throw new Error(`unknown spec type ${k}`);
}

function udtDef(e: xdr.ScSpecEntry, udts: Map<string, xdr.ScSpecEntry>, resolving: Set<string>): UdtDef {
  switch (e.switch().name) {
    case "scSpecEntryUdtStructV0":
      return {
        kind: "struct",
        fields: e.udtStructV0().fields().map((f) => ({ name: text(f.name()), type: fromSpecType(f.type(), udts, resolving) })),
      };
    case "scSpecEntryUdtEnumV0":
      return { kind: "enum", cases: e.udtEnumV0().cases().map((c) => ({ name: text(c.name()), value: c.value() })) };
    case "scSpecEntryUdtErrorEnumV0":
      return { kind: "error", cases: e.udtErrorEnumV0().cases().map((c) => ({ name: text(c.name()), value: c.value() })) };
    case "scSpecEntryUdtUnionV0":
      return {
        kind: "union",
        cases: e.udtUnionV0().cases().map((c) => {
          if (c.switch().name === "scSpecUdtUnionCaseVoidV0") return { name: text(c.voidCase().name()), types: [] };
          const tc = c.tupleCase();
          return { name: text(tc.name()), types: tc.type().map((x) => fromSpecType(x, udts, resolving)) };
        }),
      };
  }
  throw new Error(`not a user-defined type: ${e.switch().name}`);
}

/** A function's parameters as the WASM declares them; null when the WASM has no function of that name. */
export function functionParams(entries: xdr.ScSpecEntry[], fnName: string): Param[] | null {
  const udts = udtDefinitions(entries);
  for (const e of entries) {
    if (e.switch().name !== "scSpecEntryFunctionV0") continue;
    const f = e.functionV0();
    if (text(f.name()) !== fnName) continue;
    return f.inputs().map((i) => ({ name: text(i.name()), type: fromSpecType(i.type(), udts) }));
  }
  return null;
}

/** The names of every function in the spec. */
export function functionNames(entries: xdr.ScSpecEntry[]): string[] {
  return entries.filter((e) => e.switch().name === "scSpecEntryFunctionV0").map((e) => text(e.functionV0().name()));
}

// ------------------------------------------------------------------------------------------------ comparing

/** The differences between what a WASM declares and what a builder expects; empty when they match exactly. */
export function compareParams(actual: Param[] | null, expected: Param[], fnName = "__constructor"): string[] {
  if (actual === null) return [`the WASM has no ${fnName}`];
  const diffs: string[] = [];
  const n = Math.max(actual.length, expected.length);
  for (let i = 0; i < n; i++) {
    const a = actual[i];
    const e = expected[i];
    if (!a) {
      diffs.push(`parameter ${i + 1} (${e.name}: ${renderType(e.type)}) is missing from the WASM`);
      continue;
    }
    if (!e) {
      diffs.push(`the WASM has an extra parameter ${i + 1} (${a.name}: ${renderType(a.type)})`);
      continue;
    }
    if (a.name !== e.name) diffs.push(`parameter ${i + 1} is named ${a.name} in the WASM, ${e.name} in the builder`);
    const at = renderType(a.type, true);
    const et = renderType(e.type, true);
    if (at !== et) diffs.push(`parameter ${i + 1} (${e.name}): the WASM has ${at}, the builder ${et}`);
  }
  return diffs;
}

export interface GuardResult {
  ok: boolean;
  /** What the WASM declares, rendered; null when it has no such function. */
  actual: string | null;
  differences: string[];
}

/** L-d: compares the WASM's `fnName` (the constructor by default) with the builder's parameters. */
export function constructorGuard(wasm: Uint8Array, expected: Param[], fnName = "__constructor"): GuardResult {
  let entries: xdr.ScSpecEntry[];
  try {
    entries = readSpec(wasm);
  } catch (e) {
    return { ok: false, actual: null, differences: [`can't read the contract spec: ${(e as Error).message}`] };
  }
  const actual = functionParams(entries, fnName);
  const differences = compareParams(actual, expected, fnName);
  return { ok: differences.length === 0, actual: actual ? renderParams(actual) : null, differences };
}

// ------------------------------------------------------------------------------------------------ encoding values

/** Encodes `value` as the ScVal of type `t`, the way soroban-sdk decodes it (structs as maps sorted by field name,
 *  integer enums as u32, unions as `[Symbol(case), …]`). Throws on a value that doesn't fit the type. */
export function toScVal(t: SpecType, value: unknown, path = "value"): xdr.ScVal {
  const fail = (why: string): never => {
    throw new Error(`${path}: ${why}`);
  };
  switch (t.kind) {
    case "prim":
      switch (t.name) {
        case "Address":
          if (typeof value !== "string") fail("an address string is needed");
          return new Address(value as string).toScVal();
        case "bool":
          if (typeof value !== "boolean") fail("a boolean is needed");
          return xdr.ScVal.scvBool(value as boolean);
        case "u32":
        case "i32":
          if (typeof value !== "number" || !Number.isInteger(value)) fail(`an integer is needed for ${t.name}`);
          if (t.name === "u32" && ((value as number) < 0 || (value as number) > 0xffffffff)) fail("out of range for u32");
          return nativeToScVal(value, { type: t.name });
        case "u64":
        case "i64":
        case "u128":
        case "i128":
        case "U256":
        case "I256": {
          const n = toBigInt(value, fail);
          if (t.name.startsWith("u") && n < 0n) fail(`negative value for ${t.name}`);
          return nativeToScVal(n, { type: t.name.toLowerCase() as "u64" | "i64" | "u128" | "i128" | "u256" | "i256" });
        }
        case "String":
          if (typeof value !== "string") fail("a string is needed");
          return nativeToScVal(value, { type: "string" });
        case "Symbol":
          if (typeof value !== "string") fail("a symbol is needed");
          return xdr.ScVal.scvSymbol(value as string);
        case "Bytes":
          return xdr.ScVal.scvBytes(Buffer.from(toBytes(value, fail)));
        case "()":
          return xdr.ScVal.scvVoid();
        default:
          return fail(`encoding ${t.name} isn't supported`);
      }
    case "bytesN": {
      const b = toBytes(value, fail);
      if (b.length !== t.n) fail(`${t.n} bytes are needed, got ${b.length}`);
      return xdr.ScVal.scvBytes(Buffer.from(b));
    }
    case "option":
      return value === null || value === undefined ? xdr.ScVal.scvVoid() : toScVal(t.value, value, path);
    case "vec":
      if (!Array.isArray(value)) fail("a list is needed");
      return xdr.ScVal.scvVec((value as unknown[]).map((v, i) => toScVal(t.element, v, `${path}[${i}]`)));
    case "tuple":
      if (!Array.isArray(value) || value.length !== t.items.length) fail(`a ${t.items.length}-tuple is needed`);
      return xdr.ScVal.scvVec(t.items.map((it, i) => toScVal(it, (value as unknown[])[i], `${path}.${i}`)));
    case "map":
      return fail("maps aren't used by the v2 constructors");
    case "result":
      return fail("results aren't arguments");
    case "udt": {
      const d = t.def;
      if (!d) return fail(`${t.name}'s definition is unknown`);
      if (d.kind === "struct") {
        if (typeof value !== "object" || value === null) fail(`a ${t.name} object is needed`);
        const obj = value as Record<string, unknown>;
        for (const k of Object.keys(obj)) {
          if (!d.fields.some((f) => f.name === k)) fail(`${t.name} has no field ${k}`);
        }
        const tuple = d.fields.every((f, i) => f.name === String(i));
        if (tuple) return xdr.ScVal.scvVec(d.fields.map((f) => toScVal(f.type, obj[f.name], `${path}.${f.name}`)));
        const fields = [...d.fields].sort((a, b) => cmp(a.name, b.name));
        return xdr.ScVal.scvMap(fields.map((f) => {
          if (!(f.name in obj)) fail(`${t.name}.${f.name} is missing`);
          return new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(f.name), val: toScVal(f.type, obj[f.name], `${path}.${f.name}`) });
        }));
      }
      if (d.kind === "enum" || d.kind === "error") {
        const c = typeof value === "string" ? d.cases.find((x) => x.name === value) : d.cases.find((x) => x.value === value);
        if (!c) return fail(`not a ${t.name} case: ${String(value)}`);
        return xdr.ScVal.scvU32(c.value);
      }
      // union: { case, values? } or [case, ...values]
      const [name, values] = Array.isArray(value)
        ? [value[0] as string, value.slice(1)]
        : [(value as { case: string }).case, ((value as { values?: unknown[] }).values ?? [])];
      const c = d.cases.find((x) => x.name === name);
      if (!c) return fail(`not a ${t.name} case: ${String(name)}`);
      if (values.length !== c.types.length) fail(`${t.name}::${c.name} takes ${c.types.length} values`);
      return xdr.ScVal.scvVec([xdr.ScVal.scvSymbol(c.name), ...c.types.map((ty, i) => toScVal(ty, values[i], `${path}.${c.name}.${i}`))]);
    }
  }
}

function toBigInt(v: unknown, fail: (why: string) => never): bigint {
  if (typeof v === "bigint") return v;
  if (typeof v === "number" && Number.isSafeInteger(v)) return BigInt(v);
  if (typeof v === "string" && /^-?\d+$/.test(v)) return BigInt(v);
  return fail("an integer is needed");
}

function toBytes(v: unknown, fail: (why: string) => never): Uint8Array {
  if (v instanceof Uint8Array) return v;
  if (typeof v === "string" && /^([0-9a-f]{2})*$/i.test(v)) return Uint8Array.from(Buffer.from(v, "hex"));
  return fail("bytes (or a hex string) are needed");
}

/** A readable rendering of a value of type `t` (addresses as given, integers in full, bytes in hex). */
export function renderValue(t: SpecType, value: unknown, names: Map<string, string> = new Map()): string {
  const addr = (a: string) => (names.has(a) ? `${a} (${names.get(a)})` : a);
  switch (t.kind) {
    case "prim":
      if (t.name === "Address") return addr(String(value));
      if (t.name === "String") return JSON.stringify(value);
      if (t.name === "Bytes") return Buffer.from(value as Uint8Array).toString("hex");
      return String(value);
    case "bytesN":
      return typeof value === "string" ? value : Buffer.from(value as Uint8Array).toString("hex");
    case "option":
      return value === null || value === undefined ? "None" : `Some(${renderValue(t.value, value, names)})`;
    case "vec":
      return `[${(value as unknown[]).map((v) => renderValue(t.element, v, names)).join(", ")}]`;
    case "tuple":
      return `(${t.items.map((it, i) => renderValue(it, (value as unknown[])[i], names)).join(", ")})`;
    case "udt": {
      const d = t.def;
      if (d?.kind === "struct") {
        const obj = value as Record<string, unknown>;
        return `${t.name} { ${d.fields.map((f) => `${f.name}: ${renderValue(f.type, obj[f.name], names)}`).join(", ")} }`;
      }
      if (d?.kind === "enum") {
        const c = d.cases.find((x) => x.name === value || x.value === value);
        return c ? `${t.name}::${c.name}` : String(value);
      }
      return JSON.stringify(value);
    }
    default:
      return String(value);
  }
}

// ------------------------------------------------------------------------------------------------ test support

/** The spec entries that declare `fnName(params)` and every user-defined type its parameters use. For tests (a WASM
 *  carrying a given constructor) and nothing else. */
export function specEntries(fnName: string, params: Param[]): xdr.ScSpecEntry[] {
  const udts = new Map<string, xdr.ScSpecEntry>();
  const typeDef = (t: SpecType): xdr.ScSpecTypeDef => {
    switch (t.kind) {
      case "prim": {
        const k = Object.entries(PRIMS).find(([, v]) => v === t.name)![0];
        return (xdr.ScSpecTypeDef as any)[k]();
      }
      case "bytesN":
        return xdr.ScSpecTypeDef.scSpecTypeBytesN(new xdr.ScSpecTypeBytesN({ n: t.n }));
      case "option":
        return xdr.ScSpecTypeDef.scSpecTypeOption(new xdr.ScSpecTypeOption({ valueType: typeDef(t.value) }));
      case "vec":
        return xdr.ScSpecTypeDef.scSpecTypeVec(new xdr.ScSpecTypeVec({ elementType: typeDef(t.element) }));
      case "map":
        return xdr.ScSpecTypeDef.scSpecTypeMap(new xdr.ScSpecTypeMap({ keyType: typeDef(t.key), valueType: typeDef(t.value) }));
      case "tuple":
        return xdr.ScSpecTypeDef.scSpecTypeTuple(new xdr.ScSpecTypeTuple({ valueTypes: t.items.map(typeDef) }));
      case "result":
        return xdr.ScSpecTypeDef.scSpecTypeResult(new xdr.ScSpecTypeResult({ okType: typeDef(t.ok), errorType: typeDef(t.error) }));
      case "udt": {
        if (t.def && !udts.has(t.name)) {
          // A placeholder first, so a type that refers to itself doesn't recurse forever; the real entry replaces it.
          udts.set(t.name, xdr.ScSpecEntry.scSpecEntryUdtEnumV0(new xdr.ScSpecUdtEnumV0({ doc: "", lib: "", name: t.name, cases: [] })));
          udts.set(t.name, udtEntry(t.name, t.def));
        }
        return xdr.ScSpecTypeDef.scSpecTypeUdt(new xdr.ScSpecTypeUdt({ name: t.name }));
      }
    }
  };
  const udtEntry = (name: string, d: UdtDef): xdr.ScSpecEntry => {
    switch (d.kind) {
      case "struct":
        return xdr.ScSpecEntry.scSpecEntryUdtStructV0(new xdr.ScSpecUdtStructV0({
          doc: "",
          lib: "",
          name,
          fields: d.fields.map((f) => new xdr.ScSpecUdtStructFieldV0({ doc: "", name: f.name, type: typeDef(f.type) })),
        }));
      case "enum":
        return xdr.ScSpecEntry.scSpecEntryUdtEnumV0(new xdr.ScSpecUdtEnumV0({
          doc: "",
          lib: "",
          name,
          cases: d.cases.map((c) => new xdr.ScSpecUdtEnumCaseV0({ doc: "", name: c.name, value: c.value })),
        }));
      case "error":
        return xdr.ScSpecEntry.scSpecEntryUdtErrorEnumV0(new xdr.ScSpecUdtErrorEnumV0({
          doc: "",
          lib: "",
          name,
          cases: d.cases.map((c) => new xdr.ScSpecUdtErrorEnumCaseV0({ doc: "", name: c.name, value: c.value })),
        }));
      case "union":
        return xdr.ScSpecEntry.scSpecEntryUdtUnionV0(new xdr.ScSpecUdtUnionV0({
          doc: "",
          lib: "",
          name,
          cases: d.cases.map((c) =>
            c.types.length === 0
              ? xdr.ScSpecUdtUnionCaseV0.scSpecUdtUnionCaseVoidV0(new xdr.ScSpecUdtUnionCaseVoidV0({ doc: "", name: c.name }))
              : xdr.ScSpecUdtUnionCaseV0.scSpecUdtUnionCaseTupleV0(
                new xdr.ScSpecUdtUnionCaseTupleV0({ doc: "", name: c.name, type: c.types.map(typeDef) }),
              )
          ),
        }));
    }
  };
  const fn = xdr.ScSpecEntry.scSpecEntryFunctionV0(new xdr.ScSpecFunctionV0({
    doc: "",
    name: fnName,
    inputs: params.map((p) => new xdr.ScSpecFunctionInputV0({ doc: "", name: p.name, type: typeDef(p.type) })),
    outputs: [],
  }));
  return [fn, ...udts.values()];
}

/** A minimal WASM module whose only content is custom sections (name → payload). For tests. */
export function wasmWithSections(sections: [string, Uint8Array][]): Uint8Array {
  const leb = (n: number): number[] => {
    const out: number[] = [];
    do {
      let b = n & 0x7f;
      n = Math.floor(n / 128);
      if (n > 0) b |= 0x80;
      out.push(b);
    } while (n > 0);
    return out;
  };
  const parts: number[] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  for (const [name, payload] of sections) {
    const nameBytes = [...new TextEncoder().encode(name)];
    const body = [...leb(nameBytes.length), ...nameBytes, ...payload];
    parts.push(0x00, ...leb(body.length), ...body);
  }
  return Uint8Array.from(parts);
}

/** A minimal WASM module declaring `fnName(params)` in its contractspecv0 section. For tests. */
export function wasmDeclaring(fnName: string, params: Param[]): Uint8Array {
  const spec = Buffer.concat(specEntries(fnName, params).map((e) => e.toXDR()));
  return wasmWithSections([["contractspecv0", Uint8Array.from(spec)]]);
}
