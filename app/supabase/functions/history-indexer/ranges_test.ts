// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assertEquals } from "jsr:@std/assert@1";
import {
  adjacentBelow, clip, contains, gapsNewestFirst, intersects, merge, newestCovered, parseRanges, piecesDescending, size,
  subtract,
} from "./ranges.ts";

Deno.test("merge: sorts, joins overlapping and adjacent ranges, drops malformed ones", () => {
  assertEquals(merge([[10, 20], [0, 4], [5, 7], [21, 21], [30, 40], [35, 36]]), [[0, 7], [10, 21], [30, 40]]);
  assertEquals(merge([[5, 4], [-1, 3], [1.5, 2]]), []);
  assertEquals(merge([]), []);
});

Deno.test("subtract: inclusive bounds on both sides", () => {
  assertEquals(subtract([[0, 100]], [[10, 20], [50, 50], [90, 200]]), [[0, 9], [21, 49], [51, 89]]);
  assertEquals(subtract([[0, 100]], [[0, 100]]), []);
  assertEquals(subtract([[0, 10], [20, 30]], [[5, 25]]), [[0, 4], [26, 30]]);
  assertEquals(subtract([[7, 7]], []), [[7, 7]]);
});

Deno.test("gapsNewestFirst: what the window lacks, highest first", () => {
  assertEquals(gapsNewestFirst([0, 100], [[10, 20], [60, 70]]), [[71, 100], [21, 59], [0, 9]]);
  assertEquals(gapsNewestFirst([0, 100], [[0, 100]]), []);
  assertEquals(gapsNewestFirst([10, 5], []), []);
});

Deno.test("piecesDescending: aligned to multiples, newest first", () => {
  assertEquals(piecesDescending([5, 31_234], 10_000), [[30_000, 31_234], [20_000, 29_999], [10_000, 19_999], [5, 9_999]]);
  assertEquals(piecesDescending([20_000, 29_999], 10_000), [[20_000, 29_999]]);
  assertEquals(piecesDescending([7, 7], 10_000), [[7, 7]]);
  assertEquals(piecesDescending([9, 3], 10), []);
});

Deno.test("newestCovered, adjacency, intersection, clip, size, contains", () => {
  assertEquals(newestCovered([[0, 5], [10, 12]]), 12);
  assertEquals(newestCovered([]), null);
  assertEquals(adjacentBelow([11, 20], [0, 10]), true);
  assertEquals(adjacentBelow([12, 20], [0, 10]), false);
  assertEquals(intersects([5, 9], [[0, 4], [9, 12]]), true);
  assertEquals(intersects([5, 8], [[0, 4], [9, 12]]), false);
  assertEquals(clip([[0, 10], [20, 30]], [5, 25]), [[5, 10], [20, 25]]);
  assertEquals(size([[0, 9], [5, 14]]), 15);
  assertEquals(contains([[0, 10], [11, 20]], [3, 18]), true);
  assertEquals(contains([[0, 10], [12, 20]], [3, 18]), false);
});

Deno.test("parseRanges: history_ranges() output only", () => {
  assertEquals(parseRanges([[1, 2], [3, 9]]), [[1, 9]]);
  assertEquals(parseRanges([]), []);
  for (const bad of [null, "x", [[1]], [[2, 1]], [[1, "a"]], [{}]]) assertEquals(parseRanges(bad), null, JSON.stringify(bad));
});
