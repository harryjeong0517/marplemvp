// Vercel 서버 함수 — 홈페이지 주소로 그 회사 아이콘(심볼) 이미지를 찾아서 돌려줌
// GET /api/logo?url=https://www.agilent.com  →  이미지 (svg · png · ico)
// 같은 사이트 주소에서 내려주므로 화면에서 배경 지우기 · 흰색 변환 · 브랜드 컬러 뽑기를 할 수 있음
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36';
function okHost(h) { return /\./.test(h) && !/^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.)/i.test(h) && !/^\[|^\d+\.\d+\.\d+\.\d+$/.test(h); }
async function get(url, ms) {
  const c = new AbortController(); const t = setTimeout(() => c.abort(), ms || 6000);
  try { return await fetch(url, { headers: { 'User-Agent': UA, Accept: '*/*' }, redirect: 'follow', signal: c.signal }); } finally { clearTimeout(t); }
}
function attr(tag, name) { const m = tag.match(new RegExp(name + '\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i')); return m ? (m[2] || m[3] || m[4] || '') : ''; }
function candidates(html, base) {
  const out = [];
  (html.match(/<link\b[^>]*>/gi) || []).forEach(tag => {
    const rel = attr(tag, 'rel').toLowerCase(), href = attr(tag, 'href'); if (!href || !/icon/.test(rel)) return;
    let u; try { u = new URL(href.replace(/&amp;/g, '&'), base).href; } catch (e) { return; }
    const sizes = attr(tag, 'sizes'), type = attr(tag, 'type').toLowerCase();
    const n = /any/i.test(sizes) ? 512 : Math.max(0, ...(sizes.match(/\d+/g) || ['0']).map(Number));
    const svg = /svg/.test(type) || /\.svg(\?|$)/i.test(u);
    if (/mask-icon/.test(rel)) return; // 사파리용 단색 아이콘은 모양이 달라 제외
    out.push({ u, score: (svg ? 1000 : 0) + (/apple-touch/.test(rel) ? 150 : 0) + Math.min(n, 512) });
  });
  return out.sort((a, b) => b.score - a.score).map(x => x.u);
}
module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  let raw = String((req.query && req.query.url) || '').trim();
  if (!raw) return res.status(400).json({ ok: false, error: 'url 이 필요해요' });
  if (!/^https?:\/\//i.test(raw)) raw = 'https://' + raw;
  let site; try { site = new URL(raw); } catch (e) { return res.status(400).json({ ok: false, error: '주소 형식이 아니에요' }); }
  if (!okHost(site.hostname)) return res.status(400).json({ ok: false, error: '쓸 수 없는 주소예요' });
  const list = [];
  try {
    const r = await get(site.origin + (site.pathname || '/'), 7000);
    if (r.ok) { const html = (await r.text()).slice(0, 400000); list.push(...candidates(html, r.url || site.href)); }
  } catch (e) {}
  list.push(site.origin + '/apple-touch-icon.png', site.origin + '/favicon.svg', site.origin + '/favicon.ico');
  list.push('https://www.google.com/s2/favicons?sz=128&domain=' + encodeURIComponent(site.hostname));
  const seen = new Set();
  for (const u of list) {
    if (seen.has(u)) continue; seen.add(u);
    try {
      const r = await get(u, 6000); if (!r.ok) continue;
      const type = (r.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
      const buf = Buffer.from(await r.arrayBuffer());
      if (buf.length < 80 || buf.length > 1500000) continue;
      const isSvg = type.includes('svg') || /^\s*(<\?xml[^>]*>\s*)?<svg/i.test(buf.slice(0, 300).toString('utf8'));
      if (!isSvg && !/^image\//.test(type) && !/\.ico(\?|$)/i.test(u)) continue;
      res.setHeader('Content-Type', isSvg ? 'image/svg+xml' : (type.startsWith('image/') ? type : 'image/x-icon'));
      res.setHeader('Cache-Control', 'public, max-age=86400, s-maxage=604800');
      res.setHeader('X-Logo-Source', u.slice(0, 300));
      return res.status(200).send(buf);
    } catch (e) {}
  }
  return res.status(404).json({ ok: false, error: '아이콘을 찾지 못했어요' });
};
