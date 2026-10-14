// anchor: SEP-10 sign-in at the test anchor, a SEP-24 deposit, tracked in activity.
import { Keypair, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";

export default async function anchor({ api, user }: E2E): Promise<string> {
  const anchors = await api("GET", "/cash/anchors");
  const a = anchors.anchors[0];
  const toml = await (await fetch(`https://${a.domain}/.well-known/stellar.toml`)).text();
  const webAuth = toml.match(/WEB_AUTH_ENDPOINT\s*=\s*"([^"]+)"/)![1];
  const transfer = toml.match(/TRANSFER_SERVER_SEP0024\s*=\s*"([^"]+)"/)![1];
  const signingKey = toml.match(/SIGNING_KEY\s*=\s*"([^"]+)"/)![1];
  const ch = await (await fetch(`${webAuth}?account=${user.publicKey()}`)).json();
  const tx = TransactionBuilder.fromXDR(ch.transaction, ch.network_passphrase) as Transaction;
  if (!tx.signatures.some((s) => Keypair.fromPublicKey(signingKey).verify(tx.hash(), s.signature()))) throw new Error("challenge not signed by the anchor");
  if (tx.sequence !== "0") throw new Error("SEP-10 challenge must have sequence 0");
  tx.sign(user);
  const jwt = (await (await fetch(webAuth, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ transaction: tx.toEnvelope().toXDR("base64") }) })).json()).token;
  const dep = await (await fetch(`${transfer}/transactions/deposit/interactive`, {
    method: "POST",
    headers: { authorization: `Bearer ${jwt}`, "content-type": "application/json" },
    body: JSON.stringify({ asset_code: "USDC", account: user.publicKey(), lang: "en" }),
  })).json();
  if (!dep.url || !dep.id) throw new Error(JSON.stringify(dep));
  await api("POST", "/cash/track", { anchor: a.domain, kind: "deposit", asset: "USDC", anchorTxId: dep.id, status: "incomplete" });
  const act = await api("GET", "/activity");
  return `SEP-10 signed in at ${a.domain}, SEP-24 deposit ${dep.id.slice(0, 8)}… interactive URL issued, tracked; activity has ${act.items.length} items`;
}
