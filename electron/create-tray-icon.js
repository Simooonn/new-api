// Create AceHub tray icons for macOS / Windows.
// Run: node create-tray-icon.js
// Prefer: npm install canvas  (otherwise falls back to branding PNGs)

const fs = require('fs');
const path = require('path');

// Repo-level brand kit: AceHub/branding/set-03-multicolor-ring
const brandExport = path.join(
  __dirname,
  '..',
  '..',
  'branding',
  'set-03-multicolor-ring'
);

function drawAperture(ctx, size, color) {
  const s = size;
  const cx = s / 2;
  const cy = s / 2;
  const scale = s / 512;

  ctx.clearRect(0, 0, s, s);
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineCap = 'round';
  ctx.lineWidth = 54 * scale;

  // Three blades rotated 120° — matches branding/acehub/favicon.svg topology
  for (let i = 0; i < 3; i++) {
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate((i * 120 * Math.PI) / 180);
    ctx.translate(-cx, -cy);
    ctx.beginPath();
    // M256 96 C 344 96, 383 263, 323 323  (favicon path)
    ctx.moveTo(256 * scale, 96 * scale);
    ctx.bezierCurveTo(
      344 * scale,
      96 * scale,
      383 * scale,
      263 * scale,
      323 * scale,
      323 * scale
    );
    ctx.stroke();
    ctx.restore();
  }

  // Center port
  ctx.beginPath();
  ctx.arc(cx, cy, 46 * scale, 0, Math.PI * 2);
  ctx.fill();
}

function writeFromCanvas() {
  const { createCanvas } = require('canvas');

  // macOS template: black glyph on transparent, 22 / 44
  for (const [file, size] of [
    ['tray-iconTemplate.png', 22],
    ['tray-iconTemplate@2x.png', 44],
  ]) {
    const canvas = createCanvas(size, size);
    const ctx = canvas.getContext('2d');
    drawAperture(ctx, size, '#000000');
    // punch a white hole so the hub reads as a port on the menu bar
    const scale = size / 512;
    ctx.globalCompositeOperation = 'destination-out';
    ctx.beginPath();
    ctx.arc(size / 2, size / 2, 19 * scale, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    fs.writeFileSync(path.join(__dirname, file), canvas.toBuffer('image/png'));
  }

  // Windows tray: solid dark tile with light glyph
  {
    const size = 32;
    const canvas = createCanvas(size, size);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#0B1220';
    const r = 6;
    ctx.beginPath();
    ctx.moveTo(r, 0);
    ctx.arcTo(size, 0, size, size, r);
    ctx.arcTo(size, size, 0, size, r);
    ctx.arcTo(0, size, 0, 0, r);
    ctx.arcTo(0, 0, size, 0, r);
    ctx.closePath();
    ctx.fill();
    // draw glyph inset
    ctx.save();
    const pad = 3;
    ctx.translate(pad, pad);
    drawAperture(ctx, size - pad * 2, '#E2E8F0');
    const scale = (size - pad * 2) / 512;
    ctx.globalCompositeOperation = 'destination-out';
    ctx.beginPath();
    ctx.arc((size - pad * 2) / 2, (size - pad * 2) / 2, 19 * scale, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
    fs.writeFileSync(
      path.join(__dirname, 'tray-icon-windows.png'),
      canvas.toBuffer('image/png')
    );
  }

  console.log('Tray icons created from canvas (AceHub aperture).');
}

function writeFromBrandExport() {
  // Fallback when `canvas` is not installed: copy pre-exported favicon sizes.
  const map = [
    ['favicon-32.png', 'tray-icon-windows.png'],
    ['favicon-32.png', 'tray-iconTemplate.png'],
    ['favicon-64.png', 'tray-iconTemplate@2x.png'],
  ];
  for (const [srcName, destName] of map) {
    const src = path.join(brandExport, srcName);
    const dest = path.join(__dirname, destName);
    if (!fs.existsSync(src)) {
      throw new Error(`Missing brand export: ${src}`);
    }
    fs.copyFileSync(src, dest);
  }
  console.log(
    'Tray icons copied from branding/set-03-multicolor-ring (install canvas for monochrome templates).'
  );
}

try {
  writeFromCanvas();
} catch (err) {
  console.log('Canvas unavailable:', err.message);
  try {
    writeFromBrandExport();
  } catch (err2) {
    console.error('Failed to create tray icons:', err2.message);
    process.exit(1);
  }
}
