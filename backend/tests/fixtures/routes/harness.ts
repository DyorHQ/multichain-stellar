// Stand-ins for the route tests (backend/tests/unit/router.test.ts): the API runs with no network and no database.
// fetch answers from a small table (everything else is "offline"), postgres.js is replaced by a function that answers
// each query from canned rows, and the keys are derived from fixed seeds, so every response is the same on every run.
//
// ROUTE_REQUESTS is one request per route that reaches the route's handler without the network. The answers were
// recorded into this directory before the routes moved from lite/index.ts into lite/routes/ (one <name>.json each).
import { Keypair, StrKey } from "@stellar/stellar-sdk";
import type postgres from "postgres";
import { signJwt } from "../../../supabase/functions/_shared/auth.ts";
import { TESTNET } from "../../../supabase/functions/_shared/networks.ts";

// ------------------------------------------------------------------------------------------------ keys and env

const seeded = (byte: number) => Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(byte) as any);

/** The signed-in tester. */
export const USER = seeded(1);
/** Somebody else: a recipient. */
export const OTHER = seeded(3);
export const SPONSOR = seeded(2);
/** A launch token's contract id. */
export const TOKEN = StrKey.encodeContract(new Uint8Array(32).fill(7) as any);
export const XLM_SAC = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const BRIDGE_ID = "3f1c2a9e-0000-4000-8000-000000000002";
export const JWT_SECRET = "test-secret-test-secret-test-secret-0123456789";

/** Variables the API reads, as the route tests need them: testnet, the seeded sponsor, nothing hosted. */
export function setTestEnv(): void {
  Deno.env.set("LITE_JWT_SECRET", JWT_SECRET);
  Deno.env.set("LITE_NETWORK", "testnet");
  Deno.env.set("SPONSOR_SECRET", SPONSOR.secret());
  for (
    const name of [
      "KEEPER_SECRET",
      "LITE_ACTIVATION",
      "LITE_DEPLOYMENT",
      "LITE_DB_URL",
      "SUPABASE_DB_URL",
      "SUPABASE_URL",
      "SUPABASE_SERVICE_ROLE_KEY",
      "STELLAR_RPC_URL",
      "LITE_MIN_BUILD",
      "LITE_LOCAL_STORAGE_DIR",
      "LITE_PUBLIC_BASE",
    ]
  ) Deno.env.delete(name);
}

/** A session token for USER, the same on every run (HS256 over fixed claims). */
export function userToken(): Promise<string> {
  return signJwt({ sub: USER.publicKey(), net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 4_102_444_800, iat: 1_760_400_000 });
}

// ------------------------------------------------------------------------------------------------ network

const ORDER_BOOK = { bids: [{ price: "0.1900000" }], asks: [{ price: "0.1902000" }] };

/** Replaces fetch: testnet Horizon knows no account, mainnet Horizon's XLM/USDC book has one bid and one ask, and
 *  everything else (RPC, Friendbot, storage) is offline. Returns the URLs asked for. */
export function goOffline(): string[] {
  const asked: string[] = [];
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    asked.push(url.origin + url.pathname);
    if (url.host === "horizon-testnet.stellar.org" && url.pathname.startsWith("/accounts/")) {
      return Promise.resolve(Response.json({ title: "Resource Missing", status: 404 }, { status: 404 }));
    }
    if (url.host === "horizon.stellar.org" && url.pathname === "/order_book") return Promise.resolve(Response.json(ORDER_BOOK));
    return Promise.resolve(new Response("offline: unit tests make no network calls", { status: 503 }));
  }) as typeof fetch;
  return asked;
}

// ------------------------------------------------------------------------------------------------ database

export type Row = Record<string, unknown>;
/** Answers one query. `query` is the SQL text with fragments inlined, parameters as "?" and whitespace collapsed. */
export type Responder = (query: string, params: unknown[]) => Row[];

class FakeQuery implements PromiseLike<Row[]> {
  constructor(readonly text: string, readonly params: unknown[], private readonly respond: Responder) {}

  then<A = Row[], B = never>(ok?: ((rows: Row[]) => A | PromiseLike<A>) | null, fail?: ((err: unknown) => B | PromiseLike<B>) | null): Promise<A | B> {
    return Promise.resolve().then(() => this.respond(this.text, this.params)).then(ok, fail);
  }
}

/** A stand-in for postgres.js: tagged queries (and fragments inside them), sql.unsafe, sql.json, sql.begin and
 *  sql.end. A query runs when it is awaited, as with postgres.js, so a fragment never reaches the responder alone. */
export function fakeSql(respond: Responder): postgres.Sql {
  const tag = (strings: TemplateStringsArray, ...values: unknown[]) => {
    let text = strings[0];
    const params: unknown[] = [];
    values.forEach((v, i) => {
      if (v instanceof FakeQuery) {
        text += v.text;
        params.push(...v.params);
      } else {
        text += "?";
        params.push(v);
      }
      text += strings[i + 1];
    });
    return new FakeQuery(text.replace(/\s+/g, " ").trim(), params, respond);
  };
  const sql: any = Object.assign(tag, {
    unsafe: (text: string, params: unknown[] = []) => new FakeQuery(text.replace(/\s+/g, " ").trim(), params, respond),
    json: (v: unknown) => v,
    begin: async (fn: (tx: unknown) => unknown) => await fn(sql),
    end: async () => {},
  });
  return sql as postgres.Sql;
}

const at = (iso: string) => new Date(iso);

const LAUNCH_ROW: Row = {
  token: TOKEN,
  creator: OTHER.publicKey(),
  quote: XLM_SAC,
  name: "E2E Cat",
  symbol: "ECAT",
  uri: "",
  launch_index: 0,
  supply: "10000000000000000",
  quote_reserve: "300000000000",
  token_reserve: "9000000000000000",
  real_quote: "1000000000",
  threshold: "50000000000",
  completed: false,
  graduated: false,
  pair: null,
  last_price: "0.0000333",
  volume_quote: "1000000000",
  trades: 4,
  created_at: at("2026-10-13T07:00:00.000Z"),
  updated_at: at("2026-10-13T07:10:00.000Z"),
};

const MOMENT_ROW: Row = {
  id: 3,
  creator: OTHER.publicKey(),
  uri: "https://local.invalid/storage/v1/object/public/lite-media/moments/m3.json",
  title: "Accra at dusk",
  media_url: "https://local.invalid/storage/v1/object/public/lite-media/uploads/m3.jpg",
  price: "20000000",
  quote: XLM_SAC,
  max_editions: 10,
  minted: 2,
  deadline: at("2099-01-01T00:00:00.000Z"),
  created_at: at("2026-10-13T06:00:00.000Z"),
};

/** The database behind ROUTE_REQUESTS. A query nobody expected fails the request, so a route that starts reading
 *  something new shows up as a changed answer. */
export const routeRows: Responder = (q) => {
  if (/^select 1 from lite\.testers where address = \? and revoked_at is null$/.test(q)) return [{ "?column?": 1 }];
  if (q.startsWith("select value from lite.app_config")) return [{ value: { enabled: true, maintenance: false } }];
  if (q.startsWith("update lite.auth_nonces set used_at")) return [];
  if (q.startsWith("select 1 from lite.tx_log where address = ? and kind = 'faucet'")) return [{ "?column?": 1 }];
  if (/^select \* from lite\.launches .*order by/.test(q)) return [LAUNCH_ROW];
  if (q === "select * from lite.launches where token = ?") return [];
  // The launch board and a launch's page (launchpad.ts launchQuery): the board lists LAUNCH_ROW, and TOKEN has no page.
  if (q.startsWith("select l.*, greatest(l.burned, coalesce(b.burned, 0)) as burned_total")) return q.includes("where l.token = ?") ? [] : [LAUNCH_ROW];
  // The Moments feed lists MOMENT_ROW; nobody holds an edition, published one or collected (moments.ts).
  if (q.startsWith("select * from lite.moments where listed and title is not null")) return [MOMENT_ROW];
  if (q.includes("from lite.moment_editions e join lite.moments m")) return [];
  if (q.startsWith("select * from lite.moments where creator = ?")) return [];
  if (q.includes("from lite.moment_collects c join lite.moments m")) return [];
  if (q === "select * from lite.moments where id = ?") return [];
  if (q.startsWith("update lite.bridge_transfers set dest_tx")) return [];
  if (q.startsWith("select hash, kind, intent, status, ledger, created_at from lite.tx_log where address = ?")) {
    return [{
      hash: "ab".repeat(32),
      kind: "swap",
      intent: { summary: "Swap 50 XLM for at least 9.5 USDC", display: { venue: "soroswap", sell: "XLM", buy: "USDC" } },
      status: "success",
      ledger: 5_200_000,
      created_at: at("2026-10-13T08:00:00.000Z"),
    }];
  }
  if (q.startsWith("select id, direction, amount, status, created_at from lite.bridge_transfers where address = ?")) {
    return [{ id: BRIDGE_ID, direction: "stellar_to_monad", amount: "10000000", status: "attesting", created_at: at("2026-10-13T07:30:00.000Z") }];
  }
  if (q.startsWith("select id, anchor, kind, asset, amount, status, created_at from lite.anchor_transfers where address = ?")) {
    return [{ id: "5d0c1b7e-0000-4000-8000-000000000003", anchor: "testanchor.stellar.org", kind: "deposit", asset: "USDC", amount: null, status: "incomplete", created_at: at("2026-10-13T07:00:00.000Z") }];
  }
  if (q.startsWith("select token, quote, last_price from lite.launches where last_price is not null")) {
    return [{ token: TOKEN, quote: XLM_SAC, last_price: "0.0000333" }];
  }
  // The reference cache (migration 06), quoted a moment ago so that every price is current.
  if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
    return [
      { ref: "XLM", usd: "0.1901", source: "kraken", market: "Kraken XLM/USD", change_24h: "-0.0123", volume_24h_usd: "3712345.2", quoted_at: new Date() },
      { ref: "USDC", usd: "0.9999", source: "kraken", market: "Kraken USDC/USD", change_24h: "0.0001", volume_24h_usd: "912003.5", quoted_at: new Date() },
    ];
  }
  throw new Error(`unexpected query: ${q}`);
};

// ------------------------------------------------------------------------------------------------ requests

export interface RouteRequest {
  /** The fixture's file name, without .json. */
  name: string;
  method: string;
  /** From the API's own /v1/; requests go through Supabase's /functions/v1/lite/ prefix. */
  path: string;
  body?: unknown;
  /** Sent signed in as USER, and once more without a token. */
  auth: boolean;
  /** Top-level body fields that follow the clock: compared as "<volatile>". */
  volatile?: string[];
  /** Its answer gained fields on purpose since the recording: every recorded field must still be there, unchanged. */
  grown?: string;
}

const DEAD = "0x000000000000000000000000000000000000dEaD";

export const ROUTE_REQUESTS: RouteRequest[] = [
  { name: "auth-challenge-bad-address", method: "POST", path: "/v1/auth/challenge", body: { address: "not-an-address" }, auth: false },
  { name: "auth-verify-used-nonce", method: "POST", path: "/v1/auth/verify", body: { address: USER.publicKey(), nonce: "n0", signature: "c2ln" }, auth: false },
  { name: "config", method: "GET", path: "/v1/config", auth: false, grown: "the fields of docs/DESIGN-stellar-parity.md §6.2, and public caching" },
  { name: "account", method: "GET", path: "/v1/account", auth: true, grown: "the fields of docs/DESIGN-stellar-parity.md §6.4, and the public view without a token" },
  { name: "account-activate-friendbot-down", method: "POST", path: "/v1/account/activate", auth: true },
  { name: "account-trust-native", method: "POST", path: "/v1/account/trust", body: { asset: "XLM" }, auth: true },
  { name: "account-faucet-used", method: "POST", path: "/v1/account/faucet", auth: true },
  { name: "send-bad-memo-type", method: "POST", path: "/v1/send", body: { asset: "XLM", to: OTHER.publicKey(), amount: "10000000", memo: "x", memoType: "emoji" }, auth: true },
  { name: "plan-build-unknown", method: "POST", path: "/v1/plans/nope/steps/s1/build", auth: true },
  { name: "tx-submit-unknown-plan", method: "POST", path: "/v1/tx/submit", body: { planId: "nope", stepId: "s1", signedXdr: "AAAA" }, auth: true },
  { name: "tx-status-unknown", method: "GET", path: "/v1/tx/nope", auth: true },
  { name: "swap-quote-same-asset", method: "POST", path: "/v1/swap/quote", body: { sell: "XLM", buy: "XLM", amount: "10000000" }, auth: true },
  { name: "swap-build-unknown", method: "POST", path: "/v1/swap/build", body: { quoteId: "nope" }, auth: true },
  { name: "earn-markets-rpc-down", method: "GET", path: "/v1/earn/markets", auth: false },
  { name: "earn-positions-rpc-down", method: "GET", path: "/v1/earn/positions", auth: true, grown: "the public view without a token (§6.0): 400 address_required without ?address=" },
  { name: "earn-build-bad-action", method: "POST", path: "/v1/earn/build", body: { action: "borrow", pool: "C", asset: "XLM", amount: "1" }, auth: true },
  { name: "launches", method: "GET", path: "/v1/launches?sort=hot&limit=5", auth: true, grown: "the fields of docs/DESIGN-stellar-parity.md §6.9, and the public view without a token" },
  { name: "launch-unknown", method: "GET", path: `/v1/launches/${TOKEN}`, auth: true, grown: "the public view without a token (§6.0): still 404 for a token with no launch" },
  { name: "launch-quote-bad-side", method: "POST", path: `/v1/launches/${TOKEN}/quote`, body: { side: "hold", amount: "1" }, auth: true },
  { name: "launch-build-no-name", method: "POST", path: "/v1/launches/build", body: { action: "create", quote: "XLM", name: "", symbol: "ECAT" }, auth: true },
  { name: "media-upload-bad-type", method: "POST", path: "/v1/media/upload-url", body: { contentType: "text/plain", bytes: 10 }, auth: true },
  { name: "moments", method: "GET", path: "/v1/moments?limit=5", auth: true, grown: "the fields of docs/DESIGN-stellar-parity.md §6.9, and the public view without a token" },
  { name: "moments-owned", method: "GET", path: "/v1/moments/owned", auth: true, grown: "the view (§6.0); without a token, 400 address_required without ?address=" },
  { name: "moment-unknown", method: "GET", path: "/v1/moments/7", auth: true, grown: "the public view without a token (§6.0): still 404 for an id with no Moment" },
  { name: "moment-metadata-no-title", method: "POST", path: "/v1/moments/metadata", body: { title: "" }, auth: true },
  { name: "moment-build-bad-action", method: "POST", path: "/v1/moments/build", body: { action: "burn" }, auth: true },
  { name: "bridge-quote", method: "POST", path: "/v1/bridge/quote", body: { direction: "stellar_to_monad", amount: "10000000" }, auth: true },
  { name: "bridge-start-bad-direction", method: "POST", path: "/v1/bridge/start", body: { direction: "sideways", amount: "10000000", monadAddress: DEAD }, auth: true },
  { name: "bridge-source-bad-hash", method: "POST", path: `/v1/bridge/${BRIDGE_ID}/source`, body: { txHash: "nope" }, auth: true },
  { name: "bridge-claimed-unknown", method: "POST", path: `/v1/bridge/${BRIDGE_ID}/claimed`, body: { txHash: "0x" + "cd".repeat(32) }, auth: true },
  { name: "bridge-status-unknown", method: "GET", path: "/v1/bridge/nope", auth: true },
  { name: "cash-anchors", method: "GET", path: "/v1/cash/anchors?country=gh", auth: true },
  { name: "cash-track-unknown-anchor", method: "POST", path: "/v1/cash/track", body: { anchor: "example.com", kind: "deposit", asset: "USDC", anchorTxId: "1" }, auth: true },
  { name: "activity", method: "GET", path: "/v1/activity", auth: true },
  { name: "prices", method: "GET", path: "/v1/prices", auth: false, volatile: ["at"] },
  { name: "no-route", method: "GET", path: "/v1/nope", auth: false },
];

export interface Answer {
  status: number;
  headers: { "content-type": string | null; "cache-control": string | null };
  body: unknown;
  /** The exact bytes, for comparison; not stored. */
  text?: string;
}

export interface RecordedRoute {
  request: { method: string; path: string; body?: unknown; auth: boolean };
  response: Answer;
  /** The same request without a token (routes that need one). */
  anonymous?: Answer;
}

export function fixtureUrl(name: string): URL {
  return new URL(`./${name}.json`, import.meta.url);
}

/** Sends `r` (signed in when `token` is given) and reads the answer. console.error is held back meanwhile: a route
 *  that fails offline logs its error, which is expected here. */
export async function send(handle: (req: Request) => Promise<Response>, r: RouteRequest, token: string | null): Promise<Answer> {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (r.body !== undefined) headers["content-type"] = "application/json";
  const req = new Request(`http://127.0.0.1/functions/v1/lite${r.path}`, {
    method: r.method,
    headers,
    body: r.body === undefined ? undefined : JSON.stringify(r.body),
  });
  const error = console.error;
  console.error = () => {};
  try {
    const res = await handle(req);
    const text = mask(await res.text(), r.volatile);
    return {
      status: res.status,
      headers: { "content-type": res.headers.get("content-type"), "cache-control": res.headers.get("cache-control") },
      body: JSON.parse(text),
      text,
    };
  } finally {
    console.error = error;
  }
}

function mask(text: string, volatile: string[] = []): string {
  if (volatile.length === 0) return text;
  const body = JSON.parse(text);
  for (const k of volatile) if (k in body) body[k] = "<volatile>";
  return JSON.stringify(body);
}

/** Records every request's answers into this directory. */
export async function record(handle: (req: Request) => Promise<Response>): Promise<void> {
  const token = await userToken();
  for (const r of ROUTE_REQUESTS) {
    const strip = ({ text: _text, ...a }: Answer): Answer => a;
    const entry: RecordedRoute = {
      request: { method: r.method, path: r.path, ...(r.body === undefined ? {} : { body: r.body }), auth: r.auth },
      response: strip(await send(handle, r, r.auth ? token : null)),
      ...(r.auth ? { anonymous: strip(await send(handle, r, null)) } : {}),
    };
    await Deno.writeTextFile(fixtureUrl(r.name), JSON.stringify(entry, null, 2) + "\n");
  }
}
