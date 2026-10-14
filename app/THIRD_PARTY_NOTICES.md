# Third-party notices

This file credits third-party work that DyorHQ's own code is derived from, and the third-party files bundled in the
app. It is not a license for this repository. Package dependencies (Swift packages in `ios/Package.resolved`, the
Foundry libraries under `contracts/lib`, npm packages in `package-lock.json`) carry their own licenses in their
sources.

## Bundled in the app

- **TradingView Lightweight Charts™ 4.2.3** (`ios/DyorHQ/Resources/Web/lightweight-charts.standalone.production.js`),
  copyright TradingView, Inc., Apache License 2.0; its license header is kept at the top of the file.
- **Google Sans Medium**, subset to the "Continue with Google" label (`ios/DyorHQ/Resources/Fonts/GoogleSans-Medium.ttf`),
  under the SIL Open Font License 1.1 reproduced next to it in `GoogleSans-OFL.txt`.

## Mera

- **Component:** `@category-labs/mera` 0.2.0 by Category Labs: [github.com/category-labs/mera](https://github.com/category-labs/mera) (tag `v0.2.0`), npm `@category-labs/mera@0.2.0`.
- **License:** `MIT OR Apache-2.0`, at the licensee's option. DyorHQ uses it under the MIT License, reproduced below.
- **Derived work:** the Swift port in `ios/DyorKit/Sources/DyorKit/Services/Mera`. It is derived from Mera 0.2.0 and reimplements these parts in Swift:
  - the default PRF salt (`sha256("mera.prf.salt.v1")`);
  - the passkey account derivation from Mera's "Create passkey accounts" recipe (PRF output → BIP-39 → BIP-32 `m/44'/60'/0'/0/i`);
  - the `PasskeySecretVault` v1 format and its key (HKDF-SHA-256, info `mera.v1.encrypt.secret`, AES-256-GCM);
  - the registration fallback when a passkey returns no PRF output at creation;
  - the signing-session model of `createSecp256k1SigningSession` and `createEd25519SigningSession`.
- **Checked against the original:** `scripts/mera-parity` runs the published package and compares its output with the port's test vectors.

```text
Copyright (c) 2026 Category Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
