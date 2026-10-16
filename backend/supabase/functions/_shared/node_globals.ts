// The Node globals the Stellar SDK reads. `deno run` gives npm packages Node's globals, so the local stack and the tests
// never miss them, but Supabase's Edge Runtime doesn't: there the SDK's XDR code fails with "Buffer is not defined" on
// every contract read and transaction build. Each function's entry point imports this module first, before anything
// loads the SDK.
import { Buffer } from "node:buffer";

const scope = globalThis as { Buffer?: typeof Buffer };
scope.Buffer ??= Buffer;
