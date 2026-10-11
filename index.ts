import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
async function sendEmail(apiKey: string, from: string, to: string, subject: string, html: string) {
  const res = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ from, to: [to], subject, html }) });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body?.message || `Email provider returned ${res.status}`);
  return body;
}
function redact(value: string) { const at = value.indexOf('@'); return at > 0 ? `${value.slice(0,2)}***@${value.slice(at+1)}` : '***'; }

Deno.serve(async (req) => {
  // Protect this worker with a random secret in Authorization; do not expose it in the browser.
  const workerSecret = Deno.env.get('HAVENCHECK_WORKER_SECRET');
  if (!workerSecret || req.headers.get('Authorization') !== `Bearer ${workerSecret}`) return json({ error: 'Unauthorized' }, 401);
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const resendKey = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('HAVEN_EMAIL_FROM');
  if (!url || !serviceKey || !resendKey || !from) return json({ error: 'Set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY and HAVEN_EMAIL_FROM.' }, 503);
  const admin = createClient(url, serviceKey);
  const now = new Date();
  const dueIso = now.toISOString();
  const graceIso = new Date(now.getTime() - 15 * 60 * 1000).toISOString();
  let reminders = 0, contacts = 0, failures = 0;

  const { data: due, error: dueError } = await admin.from('safety_checkins').select('id,user_id,scheduled_for,reminder_sent_at,contact_alerted_at').eq('state','scheduled').lte('scheduled_for',dueIso).is('reminder_sent_at',null).limit(100);
  if (dueError) return json({ error: 'Could not read due check-ins.' }, 500);
  for (const checkin of due || []) {
    try {
      const { data: authData } = await admin.auth.admin.getUserById(checkin.user_id);
      const email = authData.user?.email;
      if (!email) throw new Error('Account email is unavailable');
      await sendEmail(resendKey, from, email, 'Your HavenCheck reminder', '<p>It is time for your HavenCheck. Please open Haven and confirm you are okay.</p><p>If you need urgent help, contact the appropriate local emergency service. Haven is not an emergency dispatch service.</p>');
      await admin.from('safety_checkins').update({ reminder_sent_at: now.toISOString() }).eq('id',checkin.id).is('reminder_sent_at',null);
      await admin.from('safety_alert_log').insert({ checkin_id: checkin.id, user_id: checkin.user_id, alert_type: 'guest_reminder', channel: 'email', recipient_redacted: redact(email), status: 'sent' });
      reminders++;
    } catch (err) {
      failures++;
      await admin.from('safety_alert_log').insert({ checkin_id: checkin.id, user_id: checkin.user_id, alert_type: 'worker_error', channel: 'email', status: 'failed', detail: String(err).slice(0,300) });
    }
  }

  const { data: late, error: lateError } = await admin.from('safety_checkins').select('id,user_id,scheduled_for,reminder_sent_at,contact_alerted_at').eq('state','scheduled').not('reminder_sent_at','is',null).lte('reminder_sent_at',graceIso).is('contact_alerted_at',null).limit(100);
  if (lateError) return json({ error: 'Could not read overdue check-ins.' }, 500);
  for (const checkin of late || []) {
    const { data: pref } = await admin.from('safety_preferences').select('trusted_contact_name,trusted_contact_method,consent_at').eq('user_id',checkin.user_id).maybeSingle();
    const method = String(pref?.trusted_contact_method || '').trim();
    // A contact is only notified with recorded consent and an email address. SMS is not silently assumed.
    const email = method.toLowerCase().startsWith('email:') ? method.slice(6).trim() : (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(method) ? method : '');
    if (!pref?.consent_at || !email) {
      await admin.from('safety_checkins').update({ state: 'missed' }).eq('id',checkin.id).eq('state','scheduled');
      await admin.from('safety_alert_log').insert({ checkin_id: checkin.id, user_id: checkin.user_id, alert_type: 'trusted_contact', channel: 'email', status: 'skipped', detail: !pref?.consent_at ? 'No recorded contact consent' : 'No valid contact email configured' });
      continue;
    }
    try {
      const name = String(pref?.trusted_contact_name || 'trusted contact').replace(/[<>&"']/g,'');
      await sendEmail(resendKey, from, email, 'HavenCheck: please check in with your contact', `<p>Hello ${name},</p><p>Your contact has not confirmed a scheduled HavenCheck after a reminder. Please try to contact them directly and follow your own local safety procedures if you believe there is immediate danger.</p><p>Haven does not automatically contact police or emergency services.</p>`);
      await admin.from('safety_checkins').update({ state: 'missed', contact_alerted_at: now.toISOString() }).eq('id',checkin.id).eq('state','scheduled').is('contact_alerted_at',null);
      await admin.from('safety_alert_log').insert({ checkin_id: checkin.id, user_id: checkin.user_id, alert_type: 'trusted_contact', channel: 'email', recipient_redacted: redact(email), status: 'sent' });
      contacts++;
    } catch (err) {
      failures++;
      await admin.from('safety_alert_log').insert({ checkin_id: checkin.id, user_id: checkin.user_id, alert_type: 'trusted_contact', channel: 'email', recipient_redacted: redact(email), status: 'failed', detail: String(err).slice(0,300) });
    }
  }
  return json({ ok: true, reminders_sent: reminders, trusted_contacts_notified: contacts, failures, checked_at: dueIso });
});
