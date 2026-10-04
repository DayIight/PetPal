// Run with Node.js and sharp available in NODE_PATH. Outputs stay beside this file.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const root = __dirname;
const write = (name, data) => fs.writeFileSync(path.join(root, name), data);
const svg = fs.readFileSync(path.join(root, 'AppIcon.svg'), 'utf8');
const inner = svg.slice(svg.indexOf('>') + 1, svg.lastIndexOf('</svg>'));
const foreground = inner.replace(/<g id="background">[\s\S]*?<\/g>/, '');
const wrap = body => `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">${body}</svg>`;
const raster = (body, name, size = 1024, opaque = false) => {
  let task = sharp(Buffer.from(body)).resize(size, size);
  if (opaque) task = task.removeAlpha();
  return task.png().toFile(path.join(root, name));
};
// A continuous superellipse is a design preview, not Apple's system mask.
const mask = Array.from({length: 256}, (_, i) => {
  const a = 2 * Math.PI * i / 256;
  const xy = v => 512 + 512 * Math.sign(v) * Math.pow(Math.abs(v), 2 / 4.5);
  return `${i ? 'L' : 'M'}${xy(Math.cos(a)).toFixed(3)} ${xy(Math.sin(a)).toFixed(3)}`;
}).join('') + 'Z';
async function main() {
  await raster(svg, 'AppIcon-1024.png', 1024, true);
  await raster(svg, 'AppIcon-60.png', 60, true);
  write('Foreground.svg', wrap(foreground));
  const bg = inner.match(/<defs>[\s\S]*?<\/defs>/)[0] + inner.match(/<g id="background">[\s\S]*?<\/g>/)[0];
  write('Background.svg', wrap(bg));
  const {data, info} = await sharp(Buffer.from(wrap(foreground))).ensureAlpha().raw().toBuffer({resolveWithObject: true});
  let minX = 1024, minY = 1024, maxX = 0, maxY = 0;
  for (let y = 0; y < info.height; y++) for (let x = 0; x < info.width; x++) {
    if (data[(y * info.width + x) * 4 + 3] > 0) {
      minX = Math.min(minX, x); minY = Math.min(minY, y);
      maxX = Math.max(maxX, x + 1); maxY = Math.max(maxY, y + 1);
    }
  }
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  let radius = 0;
  for (let y = 0; y < info.height; y++) for (let x = 0; x < info.width; x++) {
    if (data[(y * info.width + x) * 4 + 3] > 0) radius = Math.max(radius, Math.hypot(x + .5 - cx, y + .5 - cy));
  }
  const scale = Math.floor(306 / radius * 10000) / 10000;
  const transform = `translate(512 512) scale(${scale}) translate(${-cx} ${-cy})`;
  const androidFg = wrap(`<g transform="${transform}">${foreground}</g>`);
  write('Android-foreground.svg', androidFg);
  write('Android-background.svg', wrap(bg));
  await raster(androidFg, 'Android-foreground-432.png', 432);
  await raster(wrap(bg), 'Android-background-432.png', 432, true);
  const androidGuide = wrap(`${bg}<g transform="${transform}">${foreground}</g><circle cx="512" cy="512" r="312.889" fill="none" stroke="#654435" stroke-width="3" stroke-dasharray="10 8"/><rect x="170.667" y="170.667" width="682.666" height="682.666" fill="none" stroke="#654435" stroke-width="2" stroke-dasharray="4 8"/>`);
  write('Android-safe-zone.svg', androidGuide);
  await raster(androidGuide, 'Android-safe-zone.png');
  const clipped = `<defs><clipPath id="ios-preview-mask"><path d="${mask}"/></clipPath></defs><g clip-path="url(#ios-preview-mask)">${inner}</g>`;
  const panels = [];
  for (const [name, color, ink, x] of [['light', '#F6F3EE', '#654435', 0], ['dark', '#24272B', '#FFF5E7', 500]]) {
    const panel = `<rect width="500" height="640" fill="${color}"/><g font-family="Helvetica,Arial,sans-serif" fill="${ink}" text-anchor="middle"><text x="250" y="52" font-size="14" letter-spacing="3">${name.toUpperCase()} BACKGROUND</text><text x="250" y="600" font-size="13">60 × 60 px</text></g><svg x="80" y="100" width="340" height="340" viewBox="0 0 1024 1024">${clipped}</svg><svg x="220" y="510" width="60" height="60" viewBox="0 0 1024 1024">${clipped}</svg>`;
    const preview = `<svg xmlns="http://www.w3.org/2000/svg" width="500" height="640" viewBox="0 0 500 640">${panel}</svg>`;
    write(`Preview-${name}.svg`, preview);
    await sharp(Buffer.from(preview)).removeAlpha().png().toFile(path.join(root, `Preview-${name}.png`));
    panels.push(`<g transform="translate(${x} 0)">${panel}</g>`);
  }
  const board = `<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="640" viewBox="0 0 1000 640">${panels.join('')}</svg>`;
  write('Preview.svg', board);
  await sharp(Buffer.from(board)).removeAlpha().png().toFile(path.join(root, 'Preview.png'));
  const metrics = {androidScale: scale, center: [cx, cy], originalRadiusPx: radius, targetRadiusPx: scale * radius, safeRadiusPx: 1024 * 33 / 108};
  write('Geometry.json', JSON.stringify(metrics, null, 2) + '\n');
  console.log(JSON.stringify(metrics, null, 2));
}
main().catch(e => { console.error(e); process.exit(1); });
