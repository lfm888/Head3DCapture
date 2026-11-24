// Minimal TIFF inspector for single-channel float depth maps (no compression).
// usage: node scripts/inspect-tiff.mjs <file>
import { readFileSync } from 'node:fs';

const file = process.argv[2];
const buf = readFileSync(file);
const le = buf.toString('latin1', 0, 2) === 'II';
const u16 = (o) => (le ? buf.readUInt16LE(o) : buf.readUInt16BE(o));
const u32 = (o) => (le ? buf.readUInt32LE(o) : buf.readUInt32BE(o));

if (u16(2) !== 42) throw new Error('not a TIFF');

const TYPE_SIZE = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 11: 4, 12: 8, 16: 8 };
const ifdOffset = u32(4);
const count = u16(ifdOffset);
const tags = {};
for (let i = 0; i < count; i++) {
  const entry = ifdOffset + 2 + i * 12;
  const tag = u16(entry);
  const type = u16(entry + 2);
  const n = u32(entry + 4);
  const size = (TYPE_SIZE[type] ?? 1) * n;
  const valueOffset = size <= 4 ? entry + 8 : u32(entry + 8);
  const read = (idx) => {
    switch (type) {
      case 3: return u16(valueOffset + idx * 2);
      case 4: return u32(valueOffset + idx * 4);
      default: return buf[valueOffset + idx];
    }
  };
  tags[tag] = Array.from({ length: Math.min(n, 32) }, (_, k) => read(k));
}

const width = tags[256]?.[0];
const height = tags[257]?.[0];
const bits = tags[258]?.[0];
const compression = tags[259]?.[0];
const sampleFormat = tags[339]?.[0];
const strips = tags[273] ?? [];
const byteCounts = tags[279] ?? [];

console.log(`size=${width}x${height} bits=${bits} compression=${compression} sampleFormat=${sampleFormat} strips=${strips.length}`);

const values = [];
for (let s = 0; s < strips.length; s++) {
  const off = strips[s];
  const n = byteCounts[s] ?? Math.floor((byteCounts[0] ?? 0) / strips.length);
  for (let p = 0; p + 4 <= n; p += 4) {
    values.push(le ? buf.readFloatLE(off + p) : buf.readFloatBE(off + p));
  }
}
console.log(`samples=${values.length} (expected ${width * height})`);

let nan = 0, pos = 0, zero = 0;
let min = Infinity, max = -Infinity;
const bins = new Map();
for (const v of values) {
  if (Number.isNaN(v)) { nan++; continue; }
  if (!Number.isFinite(v)) { continue; }
  if (v <= 0) { zero++; continue; }
  pos++;
  if (v < min) min = v;
  if (v > max) max = v;
  const b = Math.floor(v * 20) / 20;
  bins.set(b, (bins.get(b) ?? 0) + 1);
}
console.log(`NaN=${nan} (${(nan / values.length * 100).toFixed(1)}%)  finite>0=${pos}  <=0=${zero}`);
console.log(`finite range: ${pos ? min.toFixed(4) : '-'} .. ${pos ? max.toFixed(4) : '-'} m`);
const top = [...bins.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
console.log('histogram (0.05 m bins, top 10):');
for (const [b, c] of top) console.log(`  ${b.toFixed(2)}-${(b + 0.05).toFixed(2)} m : ${c}`);
