#!/usr/bin/env node
// The dryer: which definitions are the same definition written twice.
//
//   scripts/dryer.mjs                       lib/ — report only
//   scripts/dryer.mjs lib test              the paths to read
//   scripts/dryer.mjs --enforce             fail when anything scores 0.8 or above
//   scripts/dryer.mjs --min-score 0.9 --min-tokens 40
//
// jscpd is the usual tool for this and cannot do it here: it has no Elixir
// tokeniser, so two byte-identical `.ex` files are read as zero files. What
// follows is the same idea in one file — tokenise, cut the tokens into
// five-token shingles, and score every pair of definitions by the shingles they
// share (Sørensen–Dice: 1.0 is the same definition, 0.8 says four in five).
//
// A clone is reported by its two definitions, because that is the unit a person
// fixes: two functions that say the same thing, not two line ranges. Identifiers
// stay as written, so `def render/2` and `def render_dynamic/2` with the same
// body score high — which is the point.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const SHINGLE = 5;
const MIN_SCORE = 0.8;
const MIN_TOKENS = 40;
const SHOW = 20;
const SKIP = new Set(["_build", "deps", "node_modules", "priv", "cover", "tmp", ".git"]);

// A definition starts at a line that opens one and runs to the line before the
// next definition at the same or a shallower indent. That is enough for Elixir,
// whose `def`s need no closing token, and it keeps a nested `defp` with its own
// body instead of swallowing it into the enclosing one.
const OPENER = /^(\s*)(def|defp|defmacro|defmacrop|defguard|defguardp|defdelegate)\s+([^\s(]+)/;

const TOKEN =
  /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|~[a-zA-Z](?:\[|\{|\(|\/|"|')|\b\d+(?:\.\d+)?\b|@?[A-Za-z_][A-Za-z0-9_!?]*|#\{|->|=>|<>|\|>|::|==|!=|<=|>=|\+\+|--|\w|\S/g;

const argv = process.argv.slice(2);
const enforce = argv.includes("--enforce");
const option = (name, fallback) => {
  const at = argv.indexOf(name);
  return at === -1 ? fallback : Number(argv[at + 1]);
};
const minScore = option("--min-score", MIN_SCORE);
const minTokens = option("--min-tokens", MIN_TOKENS);
const paths = argv.filter((arg, at) => !arg.startsWith("--") && !(at > 0 && argv[at - 1].startsWith("--")));
const targets = paths.length > 0 ? paths : ["lib"];

const units = targets.flatMap((path) => definitionsIn(path));
const tokens = units.reduce((sum, unit) => sum + unit.tokens.length, 0);

// Every definition, indexed by the shingles it owns. A pair sharing no shingle
// cannot score above zero, so the index is the whole search.
const owners = new Map();

for (const [index, unit] of units.entries()) {
  for (const shingle of unit.shingles) {
    const holder = owners.get(shingle) ?? [];
    holder.push(index);
    owners.set(shingle, holder);
  }
}

const seen = new Set();
const candidates = [];

for (const holder of owners.values()) {
  if (holder.length < 2 || holder.length > 200) continue;

  for (let a = 0; a < holder.length; a += 1) {
    for (let b = a + 1; b < holder.length; b += 1) {
      const key = `${holder[a]}:${holder[b]}`;
      if (seen.has(key)) continue;
      seen.add(key);
      candidates.push([holder[a], holder[b]]);
    }
  }
}

const pairs = candidates
  .map(([left, right]) => [units[left], units[right]])
  .filter(([left, right]) => left.file !== right.file || left.line !== right.line)
  .map(([left, right]) => ({ left, right, score: dice(left.shingles, right.shingles) }))
  .filter((pair) => pair.score >= minScore)
  .sort((a, b) => b.score - a.score);

console.log(
  `dryer: ${targets.join(", ")} — ${units.length} definitions, ${tokens} tokens, ` +
    `${owners.size} distinct shingles`,
);
console.log(`pairs at ${minScore} or above: ${pairs.length}`);
console.log("");

for (const { left, right, score } of pairs.slice(0, SHOW)) {
  console.log(`  ${score.toFixed(2)}  ${place(left)}  <->  ${place(right)}`);
}

if (pairs.length > SHOW) console.log(`  … ${pairs.length - SHOW} more`);

const worst = pairs[0]?.score ?? 0;
console.log("");
console.log(`worst ${worst.toFixed(2)}, threshold ${minScore}`);

if (enforce && pairs.length > 0) {
  console.error(`dryer: ${pairs.length} pair(s) at ${minScore} or above`);
  process.exitCode = 1;
} else {
  console.log(enforce ? "dryer: ok" : "dryer: report only (--enforce to fail)");
}

// --- reading -----------------------------------------------------------------

function definitionsIn(path) {
  if (!exists(path)) {
    console.error(`dryer: ${path} is not there`);
    process.exitCode = 2;
    return [];
  }

  return filesUnder(path).flatMap((file) => definitionsInFile(file));
}

function filesUnder(path) {
  const stat = statSync(path);
  if (stat.isFile()) return path.endsWith(".ex") || path.endsWith(".exs") ? [path] : [];

  return readdirSync(path, { withFileTypes: true }).flatMap((entry) =>
    SKIP.has(entry.name) ? [] : filesUnder(join(path, entry.name)),
  );
}

function definitionsInFile(file) {
  const lines = readFileSync(file, "utf8").split("\n");
  const found = [];
  let open = null;

  for (const [number, line] of lines.entries()) {
    const opener = OPENER.exec(line);

    if (opener && open === null) {
      open = { indent: opener[1].length, name: opener[3], file, line: number + 1, body: [] };
      continue;
    }

    if (opener && open !== null && opener[1].length <= open.indent) {
      found.push(open);
      open = { indent: opener[1].length, name: opener[3], file, line: number + 1, body: [] };
      continue;
    }

    if (open !== null) open.body.push(line);
  }

  if (open !== null) found.push(open);

  return found
    .map((definition) => {
      const tokens = tokenise(definition.body.join("\n"));
      return { ...definition, tokens, shingles: new Set(shinglesOf(tokens)) };
    })
    .filter((definition) => definition.tokens.length >= minTokens);
}

// --- tokens ------------------------------------------------------------------

function tokenise(source) {
  const withoutComments = source
    .split("\n")
    .map((line) => line.replace(/(^|[^?])#(?!\{).*$/, "$1"))
    .join("\n");

  return withoutComments.match(TOKEN) ?? [];
}

function shinglesOf(tokens) {
  const shingles = new Set();

  for (let at = 0; at + SHINGLE <= tokens.length; at += 1) {
    shingles.add(tokens.slice(at, at + SHINGLE).join(" "));
  }

  return shingles;
}

function dice(left, right) {
  if (left.size === 0 || right.size === 0) return 0;

  const [small, large] = left.size <= right.size ? [left, right] : [right, left];
  let shared = 0;
  for (const shingle of small) if (large.has(shingle)) shared += 1;

  return (2 * shared) / (left.size + right.size);
}

function place(unit) {
  return `${relative(process.cwd(), unit.file)}:${unit.line} ${unit.name} (${unit.tokens.length} tokens)`;
}

function exists(path) {
  try {
    statSync(path);
    return true;
  } catch {
    return false;
  }
}
