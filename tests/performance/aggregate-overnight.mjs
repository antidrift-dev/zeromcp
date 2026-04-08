#!/usr/bin/env node

/**
 * Aggregate the official-SDK and ZeroMCP overnight runs into a single combined
 * dataset. Reads every <lang>-<duration>s.json from both result directories,
 * extracts the headline metrics + per-snapshot time-series for memory plots,
 * and writes:
 *
 *   results/mixed-workload-overnight-combined.csv   — flat row per (lang × impl × duration)
 *   results/mixed-workload-overnight-combined.json  — same data + per-run snapshots
 *
 * The CSV is the source-of-truth for site/blog renderers. The JSON keeps the
 * full snapshot arrays so the memory-over-time charts have something to plot.
 *
 * Usage:  node tests/performance/aggregate-overnight.mjs
 */

import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const RESULTS_DIR = '/Users/chriswelker/Projects/antidrift/zeromcp-benchmarks/results';
const OFFICIAL_DIR = join(RESULTS_DIR, 'mixed-workload-official-overnight');
const ZEROMCP_DIR = join(RESULTS_DIR, 'mixed-workload-zeromcp-overnight');
const OUT_CSV = join(RESULTS_DIR, 'mixed-workload-overnight-combined.csv');
const OUT_JSON = join(RESULTS_DIR, 'mixed-workload-overnight-combined.json');

const FILE_RE = /^([a-z]+)-(\d+)s\.json$/;

function loadDir(dir, impl) {
  if (!existsSync(dir)) {
    console.error(`SKIP: ${dir} does not exist`);
    return [];
  }
  const rows = [];
  for (const name of readdirSync(dir).sort()) {
    const m = name.match(FILE_RE);
    if (!m) continue;
    const [, lang, durStr] = m;
    const path = join(dir, name);
    let raw;
    try {
      raw = JSON.parse(readFileSync(path, 'utf8'));
    } catch (err) {
      console.error(`SKIP ${path}: parse error ${err.message}`);
      continue;
    }
    rows.push({
      impl,
      lang,
      duration_s: parseInt(durStr, 10),
      avg_rps: raw.avg_rps ?? null,
      avg_p50_ms: raw.avg_p50_ms ?? null,
      avg_p99_ms: raw.avg_p99_ms ?? null,
      memory_min_mb: raw.memory_mb?.min ?? null,
      memory_max_mb: raw.memory_mb?.max ?? null,
      avg_cpu_pct: raw.avg_cpu_pct ?? null,
      total_errors: raw.total_errors ?? null,
      method_counts: raw.method_counts ?? null,
      snapshots: raw.snapshots ?? [],
    });
  }
  return rows;
}

function toCsv(rows) {
  const cols = [
    'impl', 'lang', 'duration_s', 'avg_rps', 'avg_p50_ms', 'avg_p99_ms',
    'memory_min_mb', 'memory_max_mb', 'avg_cpu_pct', 'total_errors',
  ];
  const lines = [cols.join(',')];
  for (const r of rows) {
    lines.push(cols.map(c => r[c] ?? '').join(','));
  }
  return lines.join('\n') + '\n';
}

function buildStabilityScores(rows) {
  // For each (impl, lang), compute max(rps)/min(rps) across the 4 durations.
  // Score of 1.0 means perfectly flat throughput. Higher means degradation.
  const groups = new Map();
  for (const r of rows) {
    const key = `${r.impl}|${r.lang}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  const scores = [];
  for (const [key, rs] of groups) {
    const [impl, lang] = key.split('|');
    const valid = rs.filter(r => typeof r.avg_rps === 'number' && r.avg_rps > 0);
    if (valid.length < 2) continue;
    const rpsValues = valid.map(r => r.avg_rps);
    const memMaxValues = valid.map(r => r.memory_max_mb).filter(v => typeof v === 'number');
    scores.push({
      impl,
      lang,
      runs: valid.length,
      rps_min: Math.min(...rpsValues),
      rps_max: Math.max(...rpsValues),
      rps_stability: Math.round((Math.max(...rpsValues) / Math.min(...rpsValues)) * 100) / 100,
      memory_growth_mb: memMaxValues.length > 0
        ? Math.round((Math.max(...memMaxValues) - Math.min(...memMaxValues)) * 10) / 10
        : null,
    });
  }
  scores.sort((a, b) => a.lang.localeCompare(b.lang) || a.impl.localeCompare(b.impl));
  return scores;
}

const officialRows = loadDir(OFFICIAL_DIR, 'official');
const zeromcpRows = loadDir(ZEROMCP_DIR, 'zeromcp');
const allRows = [...officialRows, ...zeromcpRows];

allRows.sort((a, b) =>
  a.lang.localeCompare(b.lang) ||
  a.impl.localeCompare(b.impl) ||
  a.duration_s - b.duration_s
);

writeFileSync(OUT_CSV, toCsv(allRows));

const combined = {
  type: 'mixed-workload-overnight-combined',
  generated_at: new Date().toISOString(),
  official_runs: officialRows.length,
  zeromcp_runs: zeromcpRows.length,
  total_runs: allRows.length,
  stability_scores: buildStabilityScores(allRows),
  rows: allRows,
};
writeFileSync(OUT_JSON, JSON.stringify(combined, null, 2));

// Console summary
console.log(`Loaded ${officialRows.length} official runs from ${OFFICIAL_DIR}`);
console.log(`Loaded ${zeromcpRows.length} zeromcp runs from ${ZEROMCP_DIR}`);
console.log(`Wrote ${OUT_CSV}`);
console.log(`Wrote ${OUT_JSON}`);

// Print a quick comparison table for the longest duration we have
const longest = Math.max(...allRows.map(r => r.duration_s));
const longestRows = allRows.filter(r => r.duration_s === longest);
console.log(`\n=== Headline comparison @ ${longest}s sustained ===`);
const byLang = new Map();
for (const r of longestRows) {
  if (!byLang.has(r.lang)) byLang.set(r.lang, {});
  byLang.get(r.lang)[r.impl] = r;
}
console.log('lang     | zeromcp rps | official rps | ratio | zeromcp mem | official mem');
console.log('---------|-------------|--------------|-------|-------------|-------------');
for (const [lang, rec] of [...byLang.entries()].sort()) {
  const z = rec.zeromcp;
  const o = rec.official;
  const zr = z?.avg_rps ?? '-';
  const or = o?.avg_rps ?? '-';
  const ratio = (typeof zr === 'number' && typeof or === 'number' && or > 0)
    ? (zr / or).toFixed(1) + 'x'
    : '-';
  const zm = z ? `${z.memory_min_mb}-${z.memory_max_mb} MB` : '-';
  const om = o ? `${o.memory_min_mb}-${o.memory_max_mb} MB` : '-';
  console.log(
    `${lang.padEnd(8)} | ${String(zr).padStart(11)} | ${String(or).padStart(12)} | ${ratio.padStart(5)} | ${zm.padStart(11)} | ${om.padStart(12)}`
  );
}
