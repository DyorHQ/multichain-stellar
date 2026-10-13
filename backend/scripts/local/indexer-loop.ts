// Local stand-in for the lite-indexer cron job (migration 2: pg_cron + pg_net POST every minute with x-cron-secret).
// POSTs to the local lite-indexer now and then every 60 s, and logs the time, the HTTP status and the summary the
// indexer returns. The secret is only ever sent in the header, never logged. Started by backend/scripts/local-stack.sh:
//
//   deno run --no-config --allow-env=LITE_CRON_SECRET --allow-net=127.0.0.1:8001 \
//     --env-file=.secrets/local-functions.env backend/scripts/local/indexer-loop.ts
const URL_ = "http://127.0.0.1:8001/lite-indexer";
const EVERY_MS = 60_000;
const TIMEOUT_MS = 55_000; // the cron job's net.http_post timeout

const secret = Deno.env.get("LITE_CRON_SECRET");
if (!secret) {
  console.error("indexer-loop: LITE_CRON_SECRET is not set (run with --env-file=.secrets/local-functions.env)");
  Deno.exit(1);
}

async function tick(): Promise<void> {
  const started = Date.now();
  let line: string;
  try {
    const res = await fetch(URL_, {
      method: "POST",
      headers: { "content-type": "application/json", "x-cron-secret": secret! },
      body: "{}",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const body = (await res.text()).replace(/\s+/g, " ").slice(0, 2_000);
    line = `${res.status} ${body}`;
  } catch (err) {
    line = `error ${String((err as Error)?.message ?? err).slice(0, 200)}`;
  }
  console.log(`${new Date().toISOString()} ${line}`);
  setTimeout(tick, Math.max(1_000, EVERY_MS - (Date.now() - started)));
}

console.log(`${new Date().toISOString()} indexer-loop: POST ${URL_} every ${EVERY_MS / 1000}s`);
tick();
