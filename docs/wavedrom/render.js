#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const wavedrom = require('wavedrom');

const ROOT = __dirname;
const SRC_DIR = path.join(ROOT, 'src');
const OUT_DIR = path.join(ROOT, 'svg');

function loadSource(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8');
  return JSON.parse(raw);
}

function renderToSvg(source) {
  const tree = wavedrom.renderAny(0, source, wavedrom.waveSkin, false);
  const svg = wavedrom.onml.stringify(tree);
  return `<?xml version="1.0" encoding="UTF-8"?>\n${svg}\n`;
}

function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const files = fs.readdirSync(SRC_DIR)
    .filter((name) => name.endsWith('.json'))
    .sort();

  if (files.length === 0) {
    console.log('No WaveDrom source files found.');
    return;
  }

  for (const name of files) {
    const sourcePath = path.join(SRC_DIR, name);
    const outPath = path.join(OUT_DIR, name.replace(/\.json$/i, '.svg'));
    const source = loadSource(sourcePath);
    const svg = renderToSvg(source);
    fs.writeFileSync(outPath, svg, 'utf8');
    console.log(`${path.relative(ROOT, sourcePath)} -> ${path.relative(ROOT, outPath)}`);
  }
}

main();
