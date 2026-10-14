// deno test --no-config --node-modules-dir=none -A supabase/functions/pin-media/
import { assertEquals } from "jsr:@std/assert@1";
import { Deadline, pinataResult, pinTarget } from "./pin.ts";

const W = "0x" + "a".repeat(40);
const H = "c".repeat(64);

Deno.test("SB-2: only <own wallet>/moment-<64 hex>.<jpg|mp4|mov> in launch-media", () => {
  for (const ext of ["jpg", "mp4", "mov"]) {
    assertEquals(pinTarget(undefined, `${W}/moment-${H}.${ext}`, W), { path: `${W}/moment-${H}.${ext}`, name: `moment-${H}.${ext}` });
  }
  assertEquals(pinTarget("launch-media", `${W}/moment-${H}.jpg`, W), { path: `${W}/moment-${H}.jpg`, name: `moment-${H}.jpg` });
  assertEquals((pinTarget("avatars", `${W}/moment-${H}.jpg`, W) as { status: number }).status, 400);
  assertEquals((pinTarget(undefined, `${"0x" + "b".repeat(40)}/moment-${H}.jpg`, W) as { status: number }).status, 403);
  for (const bad of [
    `${W}/moment-${H}.png`, `${W}/moment-${H.slice(1)}.jpg`, `${W}/moment-${H.toUpperCase()}.jpg`, `${W}/${H}.jpg`,
    `${W}/moment-00000000-0000-4000-8000-000000000001.jpg`, `${W}/x/moment-${H}.jpg`, `${W}/moment-${H}.jpg/`,
    `../${W}/moment-${H}.jpg`, `${W}%2Fmoment-${H}.jpg`, `${W.toUpperCase()}/moment-${H}.jpg`, `${W}/moment-${H}.jpg\n`, 42, null,
  ]) {
    assertEquals((pinTarget(undefined, bad, W) as { status: number }).status, 400, String(bad));
  }
});

Deno.test("RW-9: every step's timeout stops at the deadline", () => {
  let t = 1_000;
  const deadline = new Deadline(20_000, () => t);
  assertEquals(deadline.step(15_000), 15_000);
  t += 12_000;
  assertEquals(deadline.remaining(), 8_000);
  assertEquals(deadline.step(15_000), 8_000);
  assertEquals(deadline.step(Number.POSITIVE_INFINITY), 8_000);
  t += 9_000;
  assertEquals(deadline.remaining(), 0);
  assertEquals(deadline.step(8_000), 0);
});

Deno.test("Pinata answers: CID, wrapper directory, and duplicates (which are never unpinned)", () => {
  const cid = "bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy";
  assertEquals(pinataResult(JSON.stringify({ IpfsHash: cid, MimeType: "image/jpeg" })), { cid, mime: "image/jpeg", duplicate: false });
  assertEquals(pinataResult(JSON.stringify({ IpfsHash: cid, MimeType: "directory", isDuplicate: true })), { cid, mime: "directory", duplicate: true });
  assertEquals(pinataResult(JSON.stringify({ IpfsHash: cid, isDuplicate: "true" }))?.duplicate, false);
  for (const bad of ["", "not json", "{}", JSON.stringify({ IpfsHash: "" }), JSON.stringify({ IpfsHash: "../x" }), JSON.stringify({ IpfsHash: 5 })]) {
    assertEquals(pinataResult(bad), null, bad);
  }
});
