// moments: publish a Moment, collect 2 editions, own them.
import type { E2E } from "../lite_e2e.ts";

export default async function moments({ api, indexer, ONE, runPlan, user }: E2E): Promise<string> {
  const uri = `https://local.invalid/storage/v1/object/public/lite-media/moments/${user.publicKey()}/e2e.json`;
  const [r] = await runPlan(await api("POST", "/moments/build", { action: "publish", uri, price: (2n * ONE).toString(), quote: "XLM", maxEditions: 10, windowSecs: 7_200 }));
  const id = Number(r.returnValue);
  await indexer();
  const feed = await api("GET", "/moments");
  if (!feed.moments.some((m: any) => m.id === id)) throw new Error("moment not indexed");
  await runPlan(await api("POST", "/moments/build", { action: "collect", momentId: id, quantity: 2 }));
  await indexer();
  const owned = await api("GET", "/moments/owned");
  const mine = owned.editions.filter((x: any) => x.momentId === id).length;
  if (mine !== 2) throw new Error(`owned ${mine}`);
  return `published Moment #${id} (2 XLM, 10 editions), collected 2, own ${mine}`;
}
