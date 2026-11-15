// CloudTune Repair Worker — cloudtune-repair
// Service-worker format. Baglar: KV (opsiyonel), SENDGRID_API_KEY (secret),
// GH_TOKEN (secret, e-posta gonderilemezse kaydi depoya isler).
//
// Rotalar:
//   GET  /api/health       -> { ok: true }
//   POST /api/repair-log   -> onarim kaydi + e-posta (CloudTune@hotmail.com)
//   POST /api/device-report-> cihaz raporu (ayni sekilde saklanir)
//
// E-posta: SENDGRID_API_KEY varsa SendGrid, yoksa MailChannels, yoksa
// FormSubmit denenir. Hepsi basarisizsa kayit KV'de ve GitHub depoda tutulur;
// uygulama tarafi sessizce devam eder.

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
    // E-posta zinciri kapaliysa kayit kaybolmasin: ozel depoya not dusulur.
    let filed = false;
    if (!sent) {
      filed = await fileToRepo(kind, subject, body);
    }
    return json({ ok: true, mailed: sent, filed });
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
    if (res.ok) return true;
  } catch (_) {}

  // FormSubmit — anahtar/alan adi gerektirmez. Ilk kayitta hedef adrese
  // tek seferlik dogrulama e-postasi gider; onaylandiktan sonra kalici calisir.
  // FormSubmit yalnizca Origin/Referer ile gelen istekleri kabul eder.
  try {
    const res = await fetch(`https://formsubmit.co/ajax/${TARGET_EMAIL}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        Origin: 'https://arise1881.github.io',
        Referer: 'https://arise1881.github.io/cloudtune-dist/',
      },
      body: JSON.stringify({
        _subject: subject,
        name: 'CloudTune',
        message: text,
      }),
    });
    if (!res.ok) return false;
    const out = await res.json().catch(() => null);
    return !!out && String(out.success) === 'true';
  } catch (_) {
    return false;
  }
}

// E-posta gonderilemediginde kaydi ozel GitHub deposunda biriktirir.
// Gereken: GH_TOKEN (secret) — yalnizca issue yazma yetkisi olan token.
// GH_REPO varsayilani 'Arise1881/cloudtune-reports'.
const GH_REPO = (typeof GH_REPO_NAME !== 'undefined' && GH_REPO_NAME) || 'Arise1881/cloudtune-reports';
const GH_ISSUE_TITLE = 'CloudTune onarim kayitlari';

async function gh(method, path, body) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${GH_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'cloudtune-repair',
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`gh ${method} ${path} ${res.status}`);
  return res.json();
}

async function fileToRepo(kind, subject, text) {
  if (typeof GH_TOKEN === 'undefined' || !GH_TOKEN) return false;
  try {
    let issue = null;
    const open = await gh('GET', `/repos/${GH_REPO}/issues?state=open&per_page=30`);
    issue = (open || []).find((i) => i.title === GH_ISSUE_TITLE) || null;
    if (!issue) {
      issue = await gh('POST', `/repos/${GH_REPO}/issues`, {
        title: GH_ISSUE_TITLE,
        body: 'Uygulama onarim botunun gonderdigi kayitlar. E-posta zinciri kapaliyken buraya dusulur.',
      });
    }
    const stamp = new Date().toISOString();
    await gh('POST', `/repos/${GH_REPO}/issues/${issue.number}/comments`, {
      body: `**${stamp} · ${kind}**\n\n\`\`\`json\n${text.slice(0, 60000)}\n\`\`\`\n\n_${subject}_`,
    });
    return true;
  } catch (_) {
    return false;
  }
}
