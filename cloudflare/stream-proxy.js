// CloudTune Stream Relay Worker
// Sunucu/PC gerektirmez: Cloudflare Edge'de çalışır.
//
// Rotalar:
//   GET /health                    -> canlılık (uygulama + onarım botu kullanır)
//   GET /v1/stream/<videoId>       -> InnerTube (youtubei) ile audio URL bul + range relay
//   GET /v1/resolve?id=<videoId>   -> yalnızca audio URL'i (JSON) döndür
//   GET /stream/<base64url>        -> doğrudan URL (googlevideo/CDN) relay
//
// TR ağında googlevideo engellidir; bu worker CDN'i Cloudflare edge'den çeker.
// InnerTube birincil (güvenilir), Invidious son çare.

const AUDIO_ITAGS = [141, 251, 140, 250, 249, 338, 342, 139, 149, 600];

// InnerTube istemcileri — doğrudan (cipher'sız) audio url döndürenler tercih.
const CLIENTS = [
  {
    name: 'ANDROID',
    key: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
    client: {
      clientName: 'ANDROID',
      clientVersion: '19.09.37',
      androidSdkVersion: 30,
      osName: 'Android',
    },
    userAgent:
      'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip',
  },
  {
    name: 'ANDROID_VR',
    key: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
    client: {
      clientName: 'ANDROID_VR',
      clientVersion: '1.60.19',
      deviceMake: 'Oculus',
      deviceModel: 'Quest 3',
      androidSdkVersion: 32,
      osName: 'Android',
      osVersion: '12',
    },
    userAgent:
      'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12; GB) gzip',
  },
  {
    name: 'IOS',
    key: 'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
    client: {
      clientName: 'IOS',
      clientVersion: '19.09.3',
      deviceMake: 'Apple',
      deviceModel: 'iPhone14,3',
      osName: 'iOS',
      osVersion: '15.6.0.19G71',
    },
    userAgent:
      'com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)',
  },
];

function json(obj, status = 502) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'access-control-allow-origin': '*',
    },
  });
}

function b64urlDecode(input) {
  let s = input.replace(/-/g, '+').replace(/_/g, '/');
  const pad = s.length % 4 ? 4 - (s.length % 4) : 0;
  const bin = atob(s + '='.repeat(pad));
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function cleanTarget(target) {
  try {
    return new URL(target).toString();
  } catch (_) {
    return null;
  }
}

// Byte-range destekli passthrough relay.
async function relay(target, req) {
  const url = cleanTarget(target);
  if (!url) return json({ error: 'invalid target url' }, 400);

  const headers = new Headers();
  const range = req.headers.get('range');
  if (range) headers.set('range', range);
  headers.set('user-agent', 'Mozilla/5.0');
  headers.set('accept', '*/*');

  const res = await fetch(url, { headers, redirect: 'follow' });
  if (!res.ok && res.status !== 206) {
    return json({ error: `upstream ${res.status}` }, res.status === 404 ? 404 : 502);
  }
  return new Response(res.body, {
    status: res.status,
    headers: {
      'access-control-allow-origin': '*',
      'accept-ranges': res.headers.get('accept-ranges') || 'bytes',
      'content-type': res.headers.get('content-type') || 'audio/webm',
      'content-length': res.headers.get('content-length') || '',
      'content-range': res.headers.get('content-range') || '',
      'cache-control': 'no-store',
    },
  });
}

// InnerTube player yanıtından en iyi audio url'yi seç.
function pickAudio(formats) {
  if (!Array.isArray(formats)) return null;
  const audio = formats
    .filter((f) => f && f.url)
    .sort((a, b) => (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0));
  for (const itag of AUDIO_ITAGS) {
    const hit = audio.find((f) => Number(f.itag) === itag);
    if (hit) return hit.url;
  }
  const anyAudio = formats.find((f) => f && f.url && /audio/.test(f.mimeType || ''));
  return anyAudio ? anyAudio.url : null;
}

async function resolveViaClient(videoId, spec) {
  const body = {
    context: {
      client: spec.client,
      thirdParty: { embedUrl: 'https://www.youtube.com' },
    },
    videoId,
    contentCheckOk: true,
    racyCheckOk: true,
  };
  const headers = {
    'content-type': 'application/json',
    'accept-language': 'en-US,en;q=0.9',
    'x-youtube-client-name': spec.client.clientName,
    'x-youtube-client-version': spec.client.clientVersion,
    'user-agent': spec.userAgent,
  };
  const res = await fetch(
    `https://www.youtube.com/youtubei/v1/player?key=${spec.key}&prettyPrint=false`,
    { method: 'POST', headers, body: JSON.stringify(body) }
  );
  if (!res.ok) throw new Error(`${spec.name} http ${res.status}`);
  const data = await res.json();
  const url = pickAudio(data?.streamingData?.adaptiveFormats);
  if (url) return url;
  const st = data?.playabilityStatus?.status || 'unknown';
  throw new Error(`${spec.name} ${st}`);
}

// Invidious son çare (çoğu ölü ama ucuz deneme).
const INVIDIOUS = [
  'https://invidious.nerdvpn.de',
  'https://invidious.f5.si',
  'https://yewtu.be',
];

async function resolveViaInvidious(videoId) {
  for (const base of INVIDIOUS) {
    try {
      const res = await fetch(
        `${base}/api/v1/videos/${videoId}?fields=adaptiveFormats`,
        { headers: { 'user-agent': 'CloudTune/2.2' } }
      );
      if (!res.ok) continue;
      const data = await res.json();
      const url = pickAudio(data?.adaptiveFormats);
      if (url) return url;
    } catch (_) {}
  }
  throw new Error('invidious fallback failed');
}

async function resolveAudio(videoId) {
  const errs = [];
  for (const spec of CLIENTS) {
    try {
      return await resolveViaClient(videoId, spec);
    } catch (e) {
      errs.push(String(e.message || e));
    }
  }
  try {
    return await resolveViaInvidious(videoId);
  } catch (e) {
    errs.push(String(e.message || e));
  }
  throw new Error(errs.join(' | '));
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
          'access-control-allow-headers': '*',
        },
      });
    }

    if (path === '/health' || path === '/api/health') {
      return new Response('ok', {
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'access-control-allow-origin': '*',
        },
      });
    }

    if (path === '/v1/resolve') {
      const id = url.searchParams.get('id') || '';
      if (!/^[\w-]{11}$/.test(id)) return json({ error: 'bad id' }, 400);
      try {
        return json({ url: await resolveAudio(id) }, 200);
      } catch (e) {
        return json({ error: String(e.message || e) }, 502);
      }
    }

    if (path.startsWith('/stream/')) {
      try {
        return await relay(b64urlDecode(path.slice('/stream/'.length)), request);
      } catch (_) {
        return json({ error: 'invalid target' }, 400);
      }
    }

    if (path.startsWith('/v1/stream/')) {
      const videoId = path.slice('/v1/stream/'.length);
      if (!/^[\w-]{11}$/.test(videoId)) return json({ error: 'bad id' }, 400);
      try {
        return await relay(await resolveAudio(videoId), request);
      } catch (e) {
        return json({ error: String(e.message || e) }, 502);
      }
    }

    return json({ error: 'not found' }, 404);
  },
};
