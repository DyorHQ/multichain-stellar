// Tickers that imitate another (docs/DESIGN-stellar-parity.md §6.9, §6.11). A launch may not take a ticker that reads
// as a reserved one: create refuses it (400 look_alike_symbol), and the indexer flags a launch made directly on the
// contract with one (`look_alike`: badged, never in the markets). Reading as another goes through the fold: the
// ticker's compatibility form without accents, in upper case, with the Cyrillic and Greek capitals drawn like Latin
// ones taken as those, then 0→O, 1→I, L→I, 5→S and 8→B. Two tickers whose folds match read alike: "U5DC" and "USDĆ"
// read as USDC, "XIM" and "X1M" as XLM.
import { env } from "./env.ts";
import { NetworkConfig } from "./networks.ts";

/** Capitals of other scripts drawn exactly like Latin ones (Cyrillic, then Greek). */
const LATIN_LOOK_ALIKES: Record<string, string> = {
  "\u0410": "A", "\u0412": "B", "\u0421": "C", "\u0415": "E", "\u041D": "H", "\u0406": "I", "\u0408": "J", "\u041A": "K",
  "\u041C": "M", "\u041E": "O", "\u0420": "P", "\u0405": "S", "\u0422": "T", "\u0425": "X", "\u0423": "Y", "\u04AE": "Y",
  "\u0391": "A", "\u0392": "B", "\u0395": "E", "\u0396": "Z", "\u0397": "H", "\u0399": "I", "\u039A": "K", "\u039C": "M",
  "\u039D": "N", "\u039F": "O", "\u03A1": "P", "\u03A4": "T", "\u03A5": "Y", "\u03A7": "X",
};

/** Digits and letters drawn like the letters they are folded into. */
const DIGIT_FOLD: Record<string, string> = { "0": "O", "1": "I", "L": "I", "5": "S", "8": "B" };

/** `symbol` folded, so that two tickers that read alike fold to the same text. */
export function foldSymbol(symbol: string): string {
  const plain = symbol.normalize("NFKD").replace(/\p{M}/gu, "").toUpperCase();
  return [...plain].map((c) => LATIN_LOOK_ALIKES[c] ?? c).map((c) => DIGIT_FOLD[c] ?? c).join("");
}

/** The tickers no launch may imitate: the network's reserved list and the registry's own codes, in upper case. */
export function reservedSymbols(net: NetworkConfig = env.network): string[] {
  return [...new Set([...net.reservedSymbols, ...net.assets.map((a) => a.code)].map((s) => s.toUpperCase()))];
}

/** Whether `symbol` reads as a reserved ticker (the reserved ones themselves included). */
export function symbolLooksReserved(symbol: string, net: NetworkConfig = env.network): boolean {
  const folded = foldSymbol(symbol);
  return folded !== "" && reservedSymbols(net).some((r) => foldSymbol(r) === folded);
}
