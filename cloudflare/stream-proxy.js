// CloudTune Stream Relay Worker
// Sunucu/PC gerektirmez: Cloudflare Edge'de çalışır.
//
// Rotalar:
//   GET /health                    -> canlılık (repair bot kullanır)
//   GET /v1/stream/<videoId>       -> Invidious'tan аудио URL bulur + byte-range relay
//   GET /stream/<base64url>        -> doğrudan URL (googlevideo) relay
//
// TR ağında googlevideo engellidir; bu worker CDN'i kendi tarafında çeker,
// telefonu tek Cloudflare anycast bağlantısına indirger.

const INVIDIOUS = [
  'https://invidious.darkness.services',
  'https://invidious.ducks.party',
  'https://invidious.projectsegfau.lt',
];

const AUDIO_ITAGS = [141, 251, 140, 250, 249, 338, 342, 139];

function errJson(msg, status = 502) {
  return new Response(JSON.stringify({ error: msg }), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

function cleanTarget(url) {
  try {
    return new URL(url).toString();
  } catch (_) {
    return null;
  }
}

// Byte-range destekli passthrough relay.
async function relay(target, req) {
  const url = cleanTarget(target);
  if (!url) return errJson('invalid target url', 400);

  const headers = new Headers();
  const range = req.headers.get('range');
  if (range) headers.set('range', range);
  headers.set('user-agent', req.headers.get('user-agent') || 'Mozilla/5.0');
  headers.set('referer', req.headers.get('referer') || '');

  const res = await fetch(url, { headers, redirect: 'follow' });
  if (!res.ok && res.status !== 206) {
    return errJson(`upstream ${res.status}`, res.status === 404 ? 404 : 502);
  }
  return new Response(res.body, {
    status: res.status,
    headers: {
      'accept-ranges': res.headers.get('accept-ranges') || 'bytes',
      'content-type': res.headers.get('content-type') || 'audio/webm',
      'content-length': res.headers.get('content-length') || '',
      'content-range': res.headers.get('content-range') || '',
      'cache-control': 'no-store',
    },
  });
}

// Invidious'tan en yüksek bitrate audio URL bul.
async function resolveAudio(videoId) {
  let lastErr = null;
  for (const base of INVIDIOUS) {
    try {
      const res = await fetch(
        `${base}/api/v1/videos/${videoId}?fields=adaptiveFormats`,
        { headers: { 'user-agent': 'CloudTune/2.2' } }
      );
      if (!res.ok) {
        lastErr = new Error(`invidious http ${res.status}`);
        continue;
      }
      const data = await res.json();
      const sf = data?.adaptiveFormats;
      if (!Array.isArray(sf) || sf.length === 0) {
        lastErr = new Error('no adaptive formats');
        continue;
      }
      const audio = sf
        .filter((f) => f.url && AUDIO_ITAGS.includes(Number(f.itag)))
        .sort((a, b) => (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0));
      for (const itag of AUDIO_ITAGS) {
        const hit = audio.find((f) => Number(f.itag) === itag && f.url);
        if (hit) return hit.url;
      }
      const any = audio.find((f) => f.url);
      if (any) return any.url;
      lastErr = new Error('no playable audio url');
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error('resolve failed');
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'OPTIONS') {
      return new Response('ok', {
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET,HEAD,OPTIONS',
        },
      });
    }

    if (path === '/health' || path === '/api/health') {
      return new Response('ok', {
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }

    if (path.startsWith('/stream/')) {
      const b64 = path.slice('/stream/'.length);
      try {
        const decoded = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
        return await relay(decoded, request);
      } catch (_) {
        return errJson('bad base64', 400);
      }
    }

    if (path.startsWith('/v1/stream/')) {
      const videoId = path.slice('/v1/stream/'.length);
      if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) return errJson('bad videoId', 400);
      let audioUrl;
      try {
        audioUrl = await resolveAudio(videoId);
      } catch (e) {
        return errJson(`resolve failed: ${e.message}`);
      }
      return await relay(audioUrl, request);
    }

    return errJson('not found', 404);
  },
};