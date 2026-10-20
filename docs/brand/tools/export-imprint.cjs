/* Run with Node.js and sharp available; see ../icon-handoff.md. */
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const sharp = require('sharp');
const root = path.resolve(__dirname, '../assets/barkenson-imprint');
const sizes = [[16,1],[16,2],[32,1],[32,2],[128,1],[128,2],[256,1],[256,2],[512,1],[512,2]];
async function main() {
  const source = fs.readFileSync(path.join(root, 'barkenson-icon.svg'));
  fs.mkdirSync(path.join(root, 'Barkenson.iconset'), {recursive:true});
  for (const [pt,scale] of sizes) {
    const name = `icon_${pt}x${pt}${scale===2?'@2x':''}.png`;
    await sharp(source, {density: 288}).resize(pt*scale,pt*scale).png().toFile(path.join(root,'Barkenson.iconset',name));
  }
  await sharp(source, {density:288}).resize(1024,1024).png().toFile(path.join(root,'barkenson-icon-1024.png'));
  if (!process.argv.includes('--skip-icns')) {
    execFileSync('/usr/bin/iconutil',['-c','icns',path.join(root,'Barkenson.iconset'),'-o',path.join(root,'Barkenson.icns')]);
  }
  const cards=[];
  const labels=[];
  for (const [i,size] of [16,24,32,48,64,128,256].entries()) {
    const x=[70,170,270,390,530,720,990][i]-64;
    for(const [j,bg] of ['#F6F0E4','#272521'].entries()) {
      const y=110+j*320;
      cards.push({input: await sharp(source,{density:288}).resize(size,size).png().toBuffer(),left:Math.round(x+64-size/2),top:Math.round(y+128-size/2)});
      labels.push(`<text x="${x+64}" y="${y+284}" text-anchor="middle" fill="${j?'#FFF0D8':'#28251F'}" font-size="15">${size} px</text>`);
    }
  }
  const base=Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1170" height="800"><rect width="1170" height="800" fill="#F6F0E4"/><rect y="430" width="1170" height="370" fill="#272521"/><g font-family="Helvetica, sans-serif" fill="#28251F"><text x="40" y="48" font-size="24">Barkenson · The Imprint</text><text x="40" y="78" font-size="15">Icon scale study · actual pixel sizes · illustrative backgrounds</text>${labels.join('')}</g></svg>`);
  await sharp(base).composite(cards).png().toFile(path.join(root,'icon-scale-study.png'));
  const hashes = require('node:crypto');
  const files=['barkenson-icon.svg','barkenson-mark.svg','barkenson-icon-1024.png','Barkenson.icns',...sizes.map(([pt,scale])=>`Barkenson.iconset/icon_${pt}x${pt}${scale===2?'@2x':''}.png`)];
  fs.writeFileSync(path.join(root,'SHA256SUMS'),files.map(f=>`${hashes.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex')}  ${f}`).join('\n')+'\n');
  console.log(`Exported ${sizes.length} iconset PNGs, 1024 px PNG, scale study and checksums. ICNS ${process.argv.includes('--skip-icns')?'reused':'compiled'}.`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
