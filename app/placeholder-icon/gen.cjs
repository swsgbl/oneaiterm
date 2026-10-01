// C (task 026): generate a 1024x1024 placeholder app icon, pure Node PNG.
// Design: dark rounded-square background + a monospace prompt mark ">_"
// drawn with a lightweight 5x7 bitmap font, scaled up. No external deps.
const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

const SIZE = 1024;

// 5x7 bitmap font for the few glyphs we need
const FONT = {
  '>': [0b00010,0b00100,0b01000,0b10000,0b01000,0b00100,0b00010],
  '_': [0b00000,0b00000,0b00000,0b00000,0b00000,0b00000,0b11111],
};

const buf = Buffer.alloc(SIZE * SIZE * 4); // RGBA

const BG = [17, 22, 31];       // #11161f
const FG = [0x2f, 0x9e, 0x6e]; // terminal green #2f9e6e
const PAD = 96;
const RADIUS = 190;

function insideRounded(px, py, x0, y0, x1, y1, r) {
  if (px < x0 || px > x1 || py < y0 || py > y1) return false;
  const rx0 = x0 + r, rx1 = x1 - r, ry0 = y0 + r, ry1 = y1 - r;
  let corner = null;
  if (px < rx0 && py < ry0) corner = [rx0, ry0];
  else if (px > rx1 && py < ry0) corner = [rx1, ry0];
  else if (px < rx0 && py > ry1) corner = [rx0, ry1];
  else if (px > rx1 && py > ry1) corner = [rx1, ry1];
  if (corner) {
    const dx = px - corner[0], dy = py - corner[1];
    return dx * dx + dy * dy <= r * r;
  }
  return true;
}

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const i = (y * SIZE + x) * 4;
    if (insideRounded(x, y, PAD, PAD, SIZE - PAD, SIZE - PAD, RADIUS)) {
      buf[i] = BG[0]; buf[i + 1] = BG[1]; buf[i + 2] = BG[2]; buf[i + 3] = 255;
    } else {
      buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0;
    }
  }
}

// draw ">_" prompt centered
const GW = 5, GH = 7;
const SCALE = 90;
const glyphs = ['>', '_'];
const unitW = glyphs.length * GW + (glyphs.length - 1); // +1 space between
const totalW = unitW * SCALE;
const totalH = GH * SCALE;
const drawX0 = Math.floor((SIZE - totalW) / 2);
const drawY0 = Math.floor((SIZE - totalH) / 2);

function setPixel(px, py) {
  if (px < 0 || py < 0 || px >= SIZE || py >= SIZE) return;
  const i = (py * SIZE + px) * 4;
  if (buf[i + 3] !== 255) return;
  buf[i] = FG[0]; buf[i + 1] = FG[1]; buf[i + 2] = FG[2];
}

let gxOff = drawX0;
for (let g = 0; g < glyphs.length; g++) {
  const glyph = FONT[glyphs[g]];
  for (let row = 0; row < GH; row++) {
    for (let col = 0; col < GW; col++) {
      const bit = (glyph[row] >> (4 - col)) & 1;
      if (bit) {
        const baseX = gxOff + col * SCALE;
        const baseY = drawY0 + row * SCALE;
        for (let dy = 0; dy < SCALE; dy++) {
          for (let dx = 0; dx < SCALE; dx++) setPixel(baseX + dx, baseY + dy);
        }
      }
    }
  }
  gxOff += (GW + 1) * SCALE;
}

// PNG encode
function crc32(bufIn) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      table[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (let i = 0; i < bufIn.length; i++) crc = (crc >>> 8) ^ table[(crc ^ bufIn[i]) & 0xff];
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crcBuf = Buffer.alloc(4); crcBuf.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crcBuf]);
}

const raw = Buffer.alloc((SIZE * 4 + 1) * SIZE);
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 4 + 1)] = 0;
  buf.copy(raw, y * (SIZE * 4 + 1) + 1, y * SIZE * 4, (y + 1) * SIZE * 4);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; ihdr[9] = 6;

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

const outDir = 'D:/uniterm/kaihongos/placeholder-icon';
fs.mkdirSync(outDir, { recursive: true });
const outPath = path.join(outDir, 'app_icon_1024.png');
fs.writeFileSync(outPath, png);
console.log('wrote', outPath, png.length, 'bytes');
