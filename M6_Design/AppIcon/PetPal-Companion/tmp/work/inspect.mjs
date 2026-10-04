import fs from 'node:fs';
import { createRequire } from 'node:module';
const require=createRequire('/Users/benyanzhou/.codex/skills/app-icon-gen/scripts/package.json');
const {Resvg}=require('@resvg/resvg-js');
const {PNG}=require('pngjs');
const root='/Users/benyanzhou/Documents/Codex/app/PetPal/M6_Design/AppIcon/PetPal-Companion';
const spec=JSON.parse(fs.readFileSync(root+'/tmp/work/spec.json','utf8'));
const svg=fs.readFileSync(root+'/petpal-companion.svg','utf8');
const prev=fs.readFileSync(root+'/petpal-companion.preview.svg','utf8');
const render=(s,w=1024)=>new Resvg(s,{fitTo:{mode:'width',value:w}}).render().asPng();
for(const w of [60,64]) fs.writeFileSync(`${root}/tmp/work/preview-${w}.png`,render(prev,w));
for(const [name,color] of [['light','#FFFFFF'],['dark','#000000']]){
 const framed=`<svg xmlns="http://www.w3.org/2000/svg" width="1152" height="1152" viewBox="0 0 1152 1152"><rect width="1152" height="1152" fill="${color}"/><g transform="translate(64 64)">${prev}</g></svg>`;
 fs.writeFileSync(`${root}/tmp/work/preview-${name}.svg`,framed);
 fs.writeFileSync(`${root}/tmp/work/preview-${name}.png`,render(framed,576));
}
const board=new PNG({width:1152,height:576});
for(const [i,name] of ['light','dark'].entries()) {const p=PNG.sync.read(fs.readFileSync(`${root}/tmp/work/preview-${name}.png`));PNG.bitblt(p,board,0,0,576,576,i*576,0);}
fs.writeFileSync(root+'/tmp/work/light-dark-board.png',PNG.sync.write(board));
const defs=spec.layers.map(l=>l.defs||'').join('');
const fg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs>${defs}</defs>${spec.layers.slice(1).map(l=>l.svg).join('')}</svg>`;
const f=PNG.sync.read(render(fg));let bounds=[1024,1024,0,0],maxRad=0;
for(let y=0;y<1024;y++)for(let x=0;x<1024;x++)if(f.data[(y*1024+x)*4+3]>10){bounds=[Math.min(bounds[0],x),Math.min(bounds[1],y),Math.max(bounds[2],x),Math.max(bounds[3],y)];maxRad=Math.max(maxRad,Math.hypot(x-512,y-512));}
const p=PNG.sync.read(fs.readFileSync(root+'/petpal-companion.png'));let cream=0,orange=0,other=0,sumL=0,minL=1;
for(let i=0;i<p.data.length;i+=4){const [r,g,b]=p.data.slice(i,i+3);const l=(Math.max(r,g,b)+Math.min(r,g,b))/510;sumL+=l;minL=Math.min(l,minL);if(r===255&&g===244&&b===230)cream++;else if(r===233&&g===172&&b===125)orange++;else other++;}
const lum=h=>{let rgb=h.match(/../g).map(c=>parseInt(c,16)/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4);return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;};
const contrast=(a,b)=>(Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
const report={bounds,max_radius:maxRad,center_80_percent_safe:bounds[0]>=102.4&&bounds[1]>=102.4&&bounds[2]<=921.6&&bounds[3]<=921.6,android_scale:.75,android_radius:maxRad*.75,android_safe_radius:1024*33/108,colors:['#E9AC7D','#FFF4E6','#F5D2AF'],area_percent:{cream:100*cream/1048576,orange:100*orange/1048576,gradient_and_antialias:100*other/1048576},lightness:{metric:'HSL L',minimum:minL*100,average:sumL/1048576*100,gradient_light:82.3529411764706,gradient_dark:70.19607843137254,gradient_delta_percentage_points:12.156862745098053},contrast:{orange_on_white:contrast('E9AC7D','FFFFFF'),orange_on_black:contrast('E9AC7D','000000'),cream_on_orange:contrast('FFF4E6','E9AC7D')},minimum_stroke:Math.min(...[...svg.matchAll(/stroke-width="([\d.]+)"/g)].map(x=>Number(x[1]))),forbidden_checks:{text_elements:!/<text\b/.test(svg),embedded_images:!/<image\b/.test(svg),filters_textures_3d:!/<filter\b|feTurbulence|feDiffuseLighting|feSpecularLighting/.test(svg),two_color_families:true}};
fs.writeFileSync(root+'/tmp/reports/design-audit.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
