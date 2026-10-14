// Builds the app's REAL history_read fixture (ios/DyorKit/Tests/DyorKitTests/Fixtures/history-read-pages.json.gz,
// `HistoryDocs.realPages()` in the app's tests): one full read of a tracked wallet, every page as migration 32's
// `history_read` answers it on a throwaway PGlite database (`history_pglite_db.ts`), seeded the way the indexer writes —
// enrolment by a profile upsert, `history_commit` for every scan, `history_mark_hole` and `history_set_first_tx` — at head
// 111,727,140. The app's tests treat it as ground truth for the document's shape and paging, so when `history_read`
// changes, run this again and commit the new fixture with the change; `--check` says whether the committed one still
// matches what the migration answers (exit 1 when it doesn't). Not a test file itself; nothing here touches a real
// project.
//
//   deno run -A --no-config --node-modules-dir=none supabase/tests/make_history_read_fixture.ts [--check] [out.json.gz]
//
// The fixture is gzip with no optional header fields (what the app's loader unpacks): 44 KB for 1.1 MB of JSON. The leak
// guard unpacks and scans a gzip like any text.
import { as, historyDatabase } from "./history_pglite_db.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

const check = Deno.args.includes("--check");
const target = Deno.args.find((a) => a !== "--check")
  ?? new URL("../../ios/DyorKit/Tests/DyorKitTests/Fixtures/history-read-pages.json.gz", import.meta.url).pathname;

const W = "0x90f3e7c3b4e32494b06814fd2f4556671f5f4c47";
const B = "0x" + "b".repeat(40);
const pad = (a: string) => "0x000000000000000000000000" + a.slice(2);
const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const CURVEBUY = "0xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455";
const COLLECTED = "0xc475c499a9357ec964b24130f5e1e4b21748160d33ce0df8721acb1e370b7c96";
const MOMENTS_FACTORY = "0x95eb7f5a88b10d9df32ac54f48c767927fa80840";
const H = 111_727_140;
const HT = 1_791_497_853;
const h64 = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const word = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const log = (b: number, i: number, topics: string[], data = word(b), a = "0x" + "6".repeat(40)) =>
  ({ a, t: topics, d: data, n: data === null ? 20_000 : (data.length - 2) / 2, b, h: h64(b * 1000 + i), i, s: 1_700_000_000 + (b % 1_000_000) });

const db = await historyDatabase();
const owner = crypto.randomUUID();
const svc = (sql: string, p: unknown[] = []) => as<Any>(db, "service_role", null, sql, p);
const COMMIT = "select public.history_commit($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb) r";
const commit = (scan: string, from: number, to: number, wallets: string[] | null, logs: unknown[]) =>
  svc(COMMIT, [owner, scan, 1, from, to, H, HT, wallets, JSON.stringify(logs)]).then((r) => r[0].r);

// Enrolment, as ensureProfile's upsert does it; the lease, as a run takes it.
await as(db, "authenticated", W, "insert into public.profiles (wallet) values ($1) on conflict (wallet) do update set wallet = excluded.wallet", [W]);
await svc("select public.history_lease($1, 300, 'fixture') r", [owner]);
const scans = (await db.query<Any>("select id, floor_block::bigint::text f, def_version v from public.history_scans")).rows;
const floor = (id: string) => Number(scans.find((s: Any) => s.id === id).f);
for (const s of scans) if (s.v !== 1) throw new Error(`${s.id} at definition ${s.v}`);

// Global scans: the launchpad (three curve buys by W, one by B), fee sharing (nothing), Moments (one collect).
await commit("launchpad", floor("launchpad"), H, null, [
  log(H - 5_000, 3, [CURVEBUY, pad(W), pad(B)]), log(104_000_000, 0, [CURVEBUY, pad(W), pad(B)]), log(104_000_000, 1, [CURVEBUY, pad(W), pad(B)]),
  log(105_000_000, 0, [CURVEBUY, pad(B), pad(W)]),
]);
await commit("fee-sharing", floor("fee-sharing"), H, null, []);
await commit("moments", floor("moments"), H, null, [log(106_000_000, 2, [COLLECTED, pad(B), pad(W)], word(5), MOMENTS_FACTORY)]);

// transfers-out: 2,100 transfers from W, every 4,000 blocks down from the head (two pages of logs on their own), one
// within the 1,200 below the head; covered from genesis to the head.
const outLogs = Array.from({ length: 2_100 }, (_, k) => log(H - 600 - 4_000 * k, k % 3, [TRANSFER, pad(W), pad(B)]));
await commit("transfers-out", 0, H, [W], outLogs);
// transfers-in: 40 transfers to W and one too large to serve (omitted), covered except one block the indexer couldn't
// read (a hole).
const HOLE = 110_000_000;
const inLogs = Array.from({ length: 40 }, (_, k) => log(H - 900 - 150_000 * k, 0, [TRANSFER, pad(B), pad(W)]));
await commit("transfers-in", 0, HOLE - 1, [W], [...inLogs.filter((l) => l.b < HOLE), log(100_000_000, 9, [TRANSFER, pad(B), pad(W)], null as unknown as string)]);
await commit("transfers-in", HOLE + 1, H, [W], inLogs.filter((l) => l.b > HOLE));
await svc("select public.history_mark_hole($1, 'transfers-in', 1, $2, $3, $3)", [owner, W, HOLE]);
await svc("select public.history_set_first_tx($1, $2, 'found', 103551773, $3, 'rpc4+rpc1')", [owner, W, H]);
await svc("select public.history_release($1, $2, $3, $4::jsonb, null, 'done')", [owner, H, HT, JSON.stringify({ v: 2, stop: "done", counts: {} })]);

// One full read, as the app pages it.
const pages: Any[] = [];
let cursor: string | null = null;
do {
  const page: Any = (await as<Any>(db, "anon", null, "select public.history_read($1, $2) r", [W, cursor]))[0].r;
  pages.push(page);
  cursor = page.next;
} while (cursor && pages.length < 20);
await db.close();
const json = JSON.stringify({ wallet: W, head: H, pages });
console.log(`pages ${pages.length}, logs ${pages.map((p: Any) => Object.values(p.scans).map((s: Any) => s.logs.length).join("+")).join(" | ")}`);

async function through(data: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  return new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(stream)).arrayBuffer());
}

if (check) {
  const kept = new TextDecoder().decode(await through(await Deno.readFile(target), new DecompressionStream("gzip")));
  // The same document, whatever order its keys were written in.
  const canonical = (value: unknown): unknown =>
    Array.isArray(value) ? value.map(canonical)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((k) => [k, canonical((value as Any)[k])])) : value;
  const same = JSON.stringify(canonical(JSON.parse(kept))) === JSON.stringify(canonical(JSON.parse(json)));
  console.log(same ? `${target}: matches history_read` : `${target}: differs from what history_read answers now; run this again without --check`);
  if (!same) Deno.exit(1);
} else {
  const gzip = await through(new TextEncoder().encode(json), new CompressionStream("gzip"));
  // The app's loader takes a 10-byte header with no optional fields (flags 0), as Python's gzip.compress writes.
  if (gzip[0] !== 0x1f || gzip[1] !== 0x8b || gzip[2] !== 0x08 || gzip[3] !== 0x00) throw new Error("unexpected gzip header");
  await Deno.writeFile(target, gzip);
  console.log(`${target}: ${gzip.length} bytes`);
}
