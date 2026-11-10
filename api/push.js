// Vercel 서버 함수 — 폰 푸시 알림 보내기 (web-push · VAPID)
// Vercel 환경 변수: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY (같이 드린 vapid-keys.txt), VAPID_SUBJECT(선택, mailto:주소)
const webpush = require('web-push');
module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(200).json({ ok: true, ready: !!(process.env.VAPID_PUBLIC_KEY && process.env.VAPID_PRIVATE_KEY) });
  const pub = process.env.VAPID_PUBLIC_KEY, priv = process.env.VAPID_PRIVATE_KEY;
  if (!pub || !priv) return res.status(500).json({ ok: false, error: 'Vercel 환경 변수 VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY 가 없어요' });
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } }
  b = b || {};
  const subs = (Array.isArray(b.subs) ? b.subs : []).filter(s => s && s.endpoint && s.keys && /^https:\/\//.test(s.endpoint)).slice(0, 30);
  if (!subs.length) return res.status(200).json({ ok: true, sent: 0, gone: [] });
  webpush.setVapidDetails(process.env.VAPID_SUBJECT || 'mailto:admin@marple.co.kr', pub, priv);
  const payload = JSON.stringify({ title: String(b.title || 'MARPLE').slice(0, 80), body: String(b.body || '').slice(0, 240), url: String(b.url || 'm.html#noti').slice(0, 300), tag: b.tag ? String(b.tag).slice(0, 60) : undefined });
  const gone = []; let sent = 0;
  await Promise.all(subs.map(s => webpush.sendNotification({ endpoint: s.endpoint, keys: s.keys }, payload, { TTL: 3600 * 12 }).then(() => { sent++; }).catch(e => { if (e && (e.statusCode === 404 || e.statusCode === 410)) gone.push(s.endpoint); })));
  return res.status(200).json({ ok: true, sent, gone });
};
