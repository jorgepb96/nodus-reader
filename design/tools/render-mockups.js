// Renders .dc.html mockups to standalone HTML + PNG (static expansion of the template syntax).
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { chromium } = require('playwright');

const [, , srcDir, outHtmlDir, outPngDir] = process.argv;
fs.mkdirSync(outHtmlDir, { recursive: true });
fs.mkdirSync(outPngDir, { recursive: true });

function lookup(scope, p) {
  if (p === 'true') return true;
  if (p === 'false') return false;
  return p.split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope);
}
function esc(v) {
  return String(v).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}
function interp(str, scope) {
  return str.replace(/\{\{\s*([\w.$]+)\s*\}\}/g, (_, p) => {
    const v = lookup(scope, p);
    return v == null ? '' : esc(v);
  });
}
function ifs(str, scope) {
  return str.replace(/<sc-if value="\{\{\s*([\w.$]+)\s*\}\}"[^>]*>([\s\S]*?)<\/sc-if>/g,
    (_, p, inner) => (lookup(scope, p) ? inner : ''));
}
function expand(body, vals) {
  body = body.replace(/<sc-for list="\{\{\s*([\w.$]+)\s*\}\}" as="(\w+)"[^>]*>([\s\S]*?)<\/sc-for>/g,
    (_, listPath, as, inner) => {
      const list = lookup(vals, listPath) || [];
      return list.map((item, i) => {
        const scope = { ...vals, [as]: item, $index: i };
        return interp(ifs(inner, scope), scope);
      }).join('');
    });
  return interp(ifs(body, vals), vals);
}

(async () => {
  const browser = await chromium.launch();
  const files = fs.readdirSync(srcDir).filter((f) => f.endsWith('.dc.html')).sort();
  for (const f of files) {
    const src = fs.readFileSync(path.join(srcDir, f), 'utf8');
    const lang = (src.match(/<html lang="([^"]+)"/) || [])[1] || 'en';
    const title = (src.match(/<title>([^<]*)<\/title>/) || [])[1] || f;
    const dc = src.match(/<x-dc>([\s\S]*?)<\/x-dc>/)[1];
    const helmet = (dc.match(/<helmet>([\s\S]*?)<\/helmet>/) || [, ''])[1];
    let body = dc.replace(/<helmet>[\s\S]*?<\/helmet>/, '');
    const propsAttr = src.match(/data-props='([^']*)'/)[1].replace(/&#39;/g, "'").replace(/&amp;/g, '&');
    const propsDecl = JSON.parse(propsAttr);
    const props = {};
    for (const [k, v] of Object.entries(propsDecl)) if (k !== '$preview' && v && 'default' in v) props[k] = v.default;
    const code = src.match(/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/)[1];
    const ctx = vm.createContext({ Math, JSON });
    vm.runInContext('class DCLogic { constructor(p){ this.props = p; this.state = {}; } setState(){} forceUpdate(){} }\n' + code + '\nthis.__C = Component;', ctx);
    const vals = new ctx.__C(props).renderVals() || {};
    body = expand(body, vals);
    const { width, height } = propsDecl.$preview;
    const html = `<!doctype html>\n<html lang="${lang}">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=${width}">\n<title>${title}</title>\n${helmet.trim()}\n<style>html,body{margin:0;background:#0b0a10}</style>\n</head>\n<body>\n${body.trim()}\n</body>\n</html>\n`;
    const base = f.replace(/\.dc\.html$/, '');
    const htmlPath = path.join(outHtmlDir, base + '.html');
    fs.writeFileSync(htmlPath, html);
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
    await page.goto('file://' + path.resolve(htmlPath), { waitUntil: 'networkidle' });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(outPngDir, base + '.png'), clip: { x: 0, y: 0, width, height } });
    await page.close();
    console.log('rendered', base, width + 'x' + height);
  }
  await browser.close();
})();
