// CloudTune Repair Worker — cloudtune-repair
// Service-worker format. Baglar: SENDGRID_API_KEY (secret), KV (opsiyonel).
//
// Rotalar:
//   GET  /api/health       -> { ok: true }
//   POST /api/repair-log   -> onarim kaydi + e-posta (CloudTune@hotmail.com)
//   POST /api/device-report-> cihaz raporu (ayni sekilde saklanir)
//
// E-posta: SENDGRID_API_KEY varsa SendGrid, yoksa MailChannels denenir.
// Ikisi de yoksa kayit KV'de tutulur; uygulama tarafi sessizce devam eder.

const TARGET_EMAIL = 'CloudTune@hotmail.com';
const FROM_EMAIL = 'noreply@cloudtune.app';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'content-type',
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

addEventListener('fetch', (event) => {
  event.respondWith(handle(event.request));
});

async function handle(request) {
  const url = new URL(request.url);

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }

  if (request.method === 'GET' && url.pathname === '/api/health') {
    return json({ ok: true, service: 'cloudtune-repair', tunnel: '23d9da7b' });
  }

  if (request.method === 'POST' &&
      (url.pathname === '/api/repair-log' ||
       url.pathname === '/api/device-report')) {
    let data = {};
    try {
      data = await request.json();
    } catch (_) {
      return json({ ok: false }, 400);
    }

    const kind = url.pathname === '/api/repair-log' ? 'repair' : 'report';
    console.log(`[${kind}]`, JSON.stringify(data));

    if (typeof KV !== 'undefined') {
      try {
        await KV.put(`${kind}:${Date.now()}`, JSON.stringify(data), {
          expirationTtl: 60 * 60 * 24 * 90,
        });
        await KV.put(`${kind}:last`, JSON.stringify(data));
      } catch (_) {}
    }

    const subject = `[CloudTune ${kind}] ${data.event_type || 'event'}`;
    const body = JSON.stringify(data, null, 2);
    const sent = await sendMail(subject, body);
    return json({ ok: true, mailed: sent });
  }

  return json({ ok: false, error: 'not_found' }, 404);
}

async function sendMail(subject, text) {
  if (typeof SENDGRID_API_KEY !== 'undefined' && SENDGRID_API_KEY) {
    try {
      const res = await fetch('https://api.sendgrid.com/v3/mail/send', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${SENDGRID_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          personalizations: [{ to: [{ email: TARGET_EMAIL }] }],
          from: { email: FROM_EMAIL, name: 'CloudTune' },
          subject,
          content: [{ type: 'text/plain', value: text }],
        }),
      });
      if (res.ok) return true;
    } catch (_) {}
  }

  // MailChannels (Cloudflare-native) — alan adi SPF/DKIM dogrulanmissa calisir.
  try {
    const res = await fetch('https://api.mailchannels.net/tx/v1/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        personalizations: [{ to: [{ email: TARGET_EMAIL }] }],
        from: { email: FROM_EMAIL, name: 'CloudTune' },
        subject,
        content: [{ type: 'text/plain', value: text }],
      }),
    });
    return res.ok;
  } catch (_) {
    return false;
  }
}
