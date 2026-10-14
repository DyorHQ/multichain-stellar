// Routes answer as they did before they moved from lite/index.ts into lite/routes/: the answers recorded then are in
// backend/tests/fixtures/routes/<name>.json, and every request must get the same status, headers and body bytes.
// When a package changes a route's answer on purpose, it records them again and the diff shows what changed:
//   ROUTES_RECORD=1 deno test -A --config backend/supabase/functions/deno.json backend/tests/unit/router.test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { fakeSql, fixtureUrl, goOffline, record, RecordedRoute, ROUTE_REQUESTS, routeRows, send, setTestEnv, userToken } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
replaceSql(fakeSql(routeRows));
const { handle } = await import("../../supabase/functions/lite/index.ts");

if (Deno.env.get("ROUTES_RECORD") === "1") {
  Deno.test("record every route's answers", async () => await record(handle));
} else {
  const token = await userToken();
  for (const r of ROUTE_REQUESTS) {
    Deno.test(`${r.method} ${r.path} answers as recorded (${r.name})`, async () => {
      const recorded: RecordedRoute = JSON.parse(await Deno.readTextFile(fixtureUrl(r.name)));
      const got = await send(handle, r, r.auth ? token : null);
      assertEquals({ status: got.status, headers: got.headers }, { status: recorded.response.status, headers: recorded.response.headers });
      assertEquals(got.text, JSON.stringify(recorded.response.body));
      if (r.auth) {
        const anonymous = await send(handle, r, null);
        assertEquals(anonymous.status, 401);
        assertEquals({ status: anonymous.status, headers: anonymous.headers }, { status: recorded.anonymous!.status, headers: recorded.anonymous!.headers });
        assertEquals(anonymous.text, JSON.stringify(recorded.anonymous!.body));
      }
    });
  }
}
