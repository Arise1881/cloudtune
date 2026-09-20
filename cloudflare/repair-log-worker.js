export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });

    const data = await request.json();
    console.log('Repair escalation:', JSON.stringify(data));

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
}