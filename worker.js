// Cloudflare Worker — CORS-friendly proxy for auctions.moj.gov.jo
//
// Routes:
//   GET  /api/auction?id=<n>&token=<categoryToken>
//        Fetches AuctionInfo.aspx for that auction, parses image URLs and
//        attachment links (looking for تقرير الخبرة and similar), returns JSON.
//
//   GET  /img?u=<encoded URL>
//        Streams an image from auctions.moj.gov.jo through this worker
//        (so the browser can render <img> without CORS issues).
//
// Deploy:
//   1) https://dash.cloudflare.com/  →  Workers & Pages  →  Create  →  Worker
//   2) Replace the default code with this file's contents.  Save and deploy.
//   3) Copy the worker URL (e.g. https://moj-auctions-proxy.<account>.workers.dev)
//   4) Paste it into dashboard.html (search for WORKER_URL).
//
// Free tier: 100,000 requests/day. Plenty for personal use.

const BASE = 'https://auctions.moj.gov.jo';
const UA   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Cache-Control': 'public, max-age=300',
};

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }

    try {
      if (url.pathname === '/api/auction') {
        return await handleAuction(url);
      }
      if (url.pathname === '/api/bids') {
        return await handleBids(url);
      }
      if (url.pathname === '/img') {
        return await handleImageProxy(url);
      }
      if (url.pathname === '/' || url.pathname === '/health') {
        return jsonResponse({ ok: true, hint: 'GET /api/auction?id=&token= or /img?u= or /debug?url=' });
      }
      if (url.pathname === '/debug') {
        // Debug helper: return status, length, first chars + Set-Cookie headers from any URL on the auctions host.
        const u = url.searchParams.get('url') || (BASE + '/index.aspx');
        try {
          const r = await fetch(u, {
            headers: {
              'User-Agent': UA,
              'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Language': 'ar,en;q=0.8',
            },
            redirect: 'follow',
          });
          const txt = await r.text();
          const cookies = r.headers.getSetCookie ? r.headers.getSetCookie() : [r.headers.get('Set-Cookie') || ''];
          return jsonResponse({
            requested: u,
            finalUrl: r.url,
            status: r.status,
            length: txt.length,
            firstChars: txt.slice(0, 400),
            setCookies: cookies.filter(Boolean),
            captcha: txt.length < 5000 || txt.includes('Validation request') || txt.includes('captcha_resp'),
          });
        } catch (err) {
          return jsonResponse({ error: String(err && err.message || err) }, 500);
        }
      }
      return jsonResponse({ error: 'Not found' }, 404);
    } catch (err) {
      return jsonResponse({ error: String(err && err.message || err) }, 500);
    }
  }
};

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS }
  });
}

async function handleAuction(url) {
  const id    = url.searchParams.get('id');
  const token = url.searchParams.get('token');
  if (!id || !token) return jsonResponse({ error: 'id and token required' }, 400);

  const baseHeaders = {
    'User-Agent': UA,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'ar,en;q=0.8',
  };

  // 1) Warm the session: visit index.aspx to receive ASP.NET / BNI session cookies.
  let cookieHeader = '';
  try {
    const warm = await fetch(`${BASE}/index.aspx`, { headers: baseHeaders, redirect: 'follow' });
    const setCookies = warm.headers.getSetCookie ? warm.headers.getSetCookie() : [warm.headers.get('Set-Cookie') || ''];
    cookieHeader = setCookies
      .filter(Boolean)
      .map(c => c.split(';')[0])
      .filter(Boolean)
      .join('; ');
  } catch (e) { /* if warm fails, still try cold */ }

  // 2) Visit the category list page so the server expects subsequent details requests in this session.
  try {
    await fetch(`${BASE}/AuctionsList.aspx?token=${encodeURIComponent(token)}`, {
      headers: { ...baseHeaders, Cookie: cookieHeader, Referer: `${BASE}/index.aspx` },
      redirect: 'follow',
    });
  } catch (e) { /* ignore */ }

  // 3) Now fetch the auction detail page with the warmed cookies + Referer.
  const target = `${BASE}/AuctionInfo.aspx?token=${encodeURIComponent(token)}&auction=${encodeURIComponent(id)}`;
  const res = await fetch(target, {
    headers: {
      ...baseHeaders,
      Cookie: cookieHeader,
      Referer: `${BASE}/AuctionsList.aspx?token=${encodeURIComponent(token)}`,
    },
    redirect: 'follow',
  });
  const html = await res.text();

  if (html.length < 5000 || html.includes('Validation request') || html.includes('captcha_resp')) {
    return jsonResponse({ id: +id, captcha: true, images: [], reports: [], target });
  }

  // Image candidates
  const imgs = new Set();
  const imgRe = /<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|gif|JPG|JPEG|PNG|GIF))"/g;
  let m;
  while ((m = imgRe.exec(html))) {
    let u = m[1];
    if (/\/(noimage|logo|favicon|splash|ipad|iphone|menu|gavel|fa[-_])/.test(u)) continue;
    if (u.startsWith('data:')) continue;
    if (u.startsWith('/')) u = BASE + u;
    imgs.add(u);
  }

  // Anchor candidates → reports / attachments
  const reports = [];
  const aRe = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
  while ((m = aRe.exec(html))) {
    const href = m[1];
    const text = m[2].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    const isDoc = /\.(pdf|doc|docx|xls|xlsx|jpg|png)(\?|$)/i.test(href);
    const mentions = /(تقرير|خبرة|مرفق|التقرير|attach|report)/.test(text);
    if (isDoc || mentions) {
      let u = href;
      if (u.startsWith('/')) u = BASE + u;
      reports.push({ url: u, text: text || u });
    }
  }

  return jsonResponse({
    id: +id,
    captcha: false,
    images: [...imgs],
    reports,
    target
  });
}

// GET /api/bids?token=<categoryToken>
// Fetches page 1 of the listing for that category and parses every
// auction's current highest bid + bid count from the inline HTML.
// Each call ≈ 1 upstream request, returns JSON with up to ~30 rows.
//
// The dashboard polls this (one call per visible category) every 25 s
// and updates row cells in place.
async function handleBids(url) {
  const token = url.searchParams.get('token');
  if (!token) return jsonResponse({ error: 'token required' }, 400);

  const baseHeaders = {
    'User-Agent': UA,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'ar,en;q=0.8',
  };

  // Warm session so the listing page doesn't anti-bot us.
  let cookieHeader = '';
  try {
    const warm = await fetch(`${BASE}/index.aspx`, { headers: baseHeaders, redirect: 'follow' });
    const setCookies = warm.headers.getSetCookie ? warm.headers.getSetCookie() : [warm.headers.get('Set-Cookie') || ''];
    cookieHeader = setCookies.filter(Boolean).map(c => c.split(';')[0]).filter(Boolean).join('; ');
  } catch (e) {}

  const listUrl = `${BASE}/AuctionsList.aspx?token=${encodeURIComponent(token)}`;
  const r = await fetch(listUrl, {
    headers: { ...baseHeaders, Cookie: cookieHeader, Referer: `${BASE}/index.aspx` },
    redirect: 'follow',
  });
  const html = await r.text();
  if (html.length < 5000 || html.includes('Validation request') || html.includes('captcha_resp')) {
    return jsonResponse({ token, captcha: true, updates: [] });
  }

  // Parse every (auctionId, currentAmount, numBids) on this page.
  // These spans look like:
  //   <span ... id="HighestAuctionAmount_50880">7111.11 </span>
  //   <span ... id="NumberOfBiddings_50880">5 </span>
  const updates = new Map();
  const highRe = /HighestAuctionAmount_(\d+)"[^>]*>\s*([^<\s]+)/g;
  let m;
  while ((m = highRe.exec(html))) {
    const id = +m[1];
    const v  = parseFloat(m[2].replace(/[^\d.\-]/g, ''));
    if (!updates.has(id)) updates.set(id, { id, currentAmount: isNaN(v) ? 0 : v, numBids: 0 });
    else updates.get(id).currentAmount = isNaN(v) ? 0 : v;
  }
  const numRe = /NumberOfBiddings_(\d+)"[^>]*>\s*(\d+)/g;
  while ((m = numRe.exec(html))) {
    const id = +m[1];
    const n  = parseInt(m[2], 10) || 0;
    if (!updates.has(id)) updates.set(id, { id, currentAmount: 0, numBids: n });
    else updates.get(id).numBids = n;
  }

  return jsonResponse({
    token,
    captcha: false,
    count: updates.size,
    updates: [...updates.values()],
    ts: Date.now(),
  });
}

async function handleImageProxy(url) {
  const u = url.searchParams.get('u');
  if (!u) return jsonResponse({ error: 'u required' }, 400);
  // Only proxy URLs on the auctions host
  let target;
  try { target = new URL(u); } catch { return jsonResponse({ error: 'bad URL' }, 400); }
  if (target.hostname !== 'auctions.moj.gov.jo') {
    return jsonResponse({ error: 'host not allowed' }, 400);
  }
  const res = await fetch(target.toString(), { headers: { 'User-Agent': UA } });
  const headers = new Headers(CORS);
  const ct = res.headers.get('Content-Type') || 'application/octet-stream';
  headers.set('Content-Type', ct);
  return new Response(res.body, { status: res.status, headers });
}
