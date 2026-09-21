// CloudTune Repair Log Worker — service-worker format.
// Bağlamalar (SENDGRID_API_KEY, KV) classic format'ta global değişken olur.

addEventListener('fetch', (event) => {
  event.respondWith(handle(event.request));
});

async function handle(request) {
  const url = new URL(request.url);

  if (request.method === 'POST' && url.pathname.startsWith('/api/repair-log')) {
    const data = await request.json();
    console.log('Repair escalation:', JSON.stringify(data));

    if (typeof KV !== 'undefined') {
      await KV.put(
        `repair:${Date.now()}`,
        JSON.stringify(data),
        { expirationTtl: 60 * 60 * 24 * 30 } // 30 gün sakla
      );
      await KV.put('repair:last', JSON.stringify(data));
    }

    if (typeof SENDGRID_API_KEY !== 'undefined') {
      await fetch('https://api.sendgrid.com/v3/mail/send', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${SENDGRID_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          personalizations: [{ to: [{ email: 'CloudTune@hotmail.com' }] }],
          from: { email: 'noreply@cloudtune.app' },
          subject: `[CloudTune Repair] ${data.event_type}`,
          content: [{ type: 'text/plain', value: JSON.stringify(data, null, 2) }]
        })
      });
    }

    return ok();
  }

  if (request.method === 'POST' && url.pathname.startsWith('/api/device-report')) {
    const data = await request.json();
    console.log('Device report:', JSON.stringify(data));
    if (typeof KV !== 'undefined') {
      await KV.put(
        `report:${Date.now()}`,
        JSON.stringify(data),
        { expirationTtl: 60 * 60 * 24 * 90 }
      );
    }
    return ok();
  }

  if (request.method === 'GET' && url.pathname === '/api/health') {
    return new Response(JSON.stringify({ ok: true, service: 'cloudtune-repair' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  return new Response('Not found', { status: 404 });
}

function ok() {
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  });
}