// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
import { assertEquals } from "jsr:@std/assert@1";
import { clientNet } from "./net.ts";

const req = (headers: Record<string, string>) => new Request("https://x.test/", { headers });

Deno.test("clientNet: IPv4 per address, IPv6 per /64, mapped IPv4 as IPv4, never X-Forwarded-For", () => {
  assertEquals(clientNet(req({ "cf-connecting-ip": "203.0.113.9" })), "203.0.113.9");
  assertEquals(clientNet(req({ "cf-connecting-ip": " 203.0.113.9 " })), "203.0.113.9");
  assertEquals(clientNet(req({ "cf-connecting-ip": "256.1.1.1" })), null);
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:DB8:1:2:3:4:5:6" })), "2001:db8:1:2::/64");
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:db8:1:2::9" })), "2001:db8:1:2::/64");
  assertEquals(clientNet(req({ "cf-connecting-ip": "::ffff:198.51.100.4" })), "198.51.100.4");
  assertEquals(clientNet(req({ "cf-connecting-ip": "not-an-ip" })), null);
  assertEquals(clientNet(req({ "x-forwarded-for": "198.51.100.1" })), null);
  assertEquals(clientNet(req({ "x-real-ip": "198.51.100.1" })), null);
  assertEquals(clientNet(req({})), null);
});

Deno.test("clientNet: coarser IPv6 buckets on request (/56, /48); IPv4 unchanged", () => {
  const v6 = req({ "cf-connecting-ip": "2001:db8:abcd:12ff:3:4:5:6" });
  assertEquals(clientNet(v6), "2001:db8:abcd:12ff::/64");
  assertEquals(clientNet(v6, 64), "2001:db8:abcd:12ff::/64");
  assertEquals(clientNet(v6, 56), "2001:db8:abcd:1200::/56");
  assertEquals(clientNet(v6, 48), "2001:db8:abcd::/48");
  // Every /64 inside one /48 is the same /48 bucket; the next /48 is not.
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:db8:abcd:ffff::1" }), 48), "2001:db8:abcd::/48");
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:db8:abce::1" }), 48), "2001:db8:abce::/48");
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:db8:abcd:12aa::1" }), 56), "2001:db8:abcd:1200::/56");
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:db8:abcd:1300::1" }), 56), "2001:db8:abcd:1300::/56");
  assertEquals(clientNet(req({ "cf-connecting-ip": "203.0.113.9" }), 48), "203.0.113.9");
  assertEquals(clientNet(req({ "cf-connecting-ip": "::ffff:198.51.100.4" }), 48), "198.51.100.4");
});
