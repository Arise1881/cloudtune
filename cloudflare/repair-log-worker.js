export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'POST' && url.pathname.startsWith('/api/repair-log')) {
      const data = await request.json();
      console.log('Repair escalation:', JSON.stringify(data));

      if (env.KV) {
        await env.KV.put(
          `repair:${Date.now()}`,
          JSON.stringify(data),
          { expirationTtl: 60 * 60 * 24 * 30 } // 30 gün sakla
        );
        await env.KV.put('repair:last', JSON.stringify(data));
      }

      if (env.SENDGRID_API_KEY) {
        await fetch('https://api.sendgrid.com/v3/mail/send', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${env.SENDGRID_API_KEY}`,
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

      return new Response(JSON.stringify({ ok: true }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    if (request.method === 'POST' && url.pathname.startsWith('/api/device-report')) {
      // Ayarlar > "Uzaktan Onarım Raporu" e-postası; ayrı yazı durumu korunur
      // (uzaktan onarım ajanları için). Gelen gövde olduğu gibi saklanır.
      const data = await request.json();
      console.log('Device report:', JSON.stringify(data));
      if (env.KV) {
        await env.KV.put(
          `report:${Date.now()}`,
          JSON.stringify(data),
          { expirationTtl: 60 * 60 * 24 * 90 }
        );
      }
      return new Response(JSON.stringify({ ok: true }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    if (request.method === 'GET' && url.pathname === '/api/health') {
      return new Response(JSON.stringify({ ok: true, service: 'cloudtune-repair' }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    return new Response('Not found', { status: 404 });
  }
}