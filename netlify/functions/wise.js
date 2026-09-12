// Wise Business API proxy.
//
// Keeps WISE_API_TOKEN off the client, and — since this URL is public — only
// proxies for a signed-in admin. Order matters: verify the caller BEFORE
// looking at the path or touching api.wise.com.
//
//   1. Authorization: Bearer <supabase access token>  (missing → 401)
//   2. token verified against Supabase /auth/v1/user   (invalid → 401)
//   3. caller's role read from public.staff server-side (not from the token,
//      which the client controls)                      (not admin → 403)
//   4. path prefix allow-list                          (other → 403)
//
// Netlify env vars:
//   WISE_API_TOKEN              (required) Wise Business API token.
//   SUPABASE_SERVICE_ROLE_KEY   (optional but recommended) reads public.staff
//                               bypassing RLS. Without it the role is read with
//                               the caller's own token, which RLS limits to
//                               their own staff row — the same answer, just
//                               dependent on that policy staying in place.
//   SUPABASE_URL / SUPABASE_ANON_KEY (optional) default to the constants below;
//                               both are public values already in index.html.
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://bhqjsqwbsbhjuhjwxwcp.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJocWpzcXdic2JoanVoand4d2NwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU4NzM3ODIsImV4cCI6MjA5MTQ0OTc4Mn0.K4X9VClrSfnvSSAZE1LMwQPWVo9fdycx1SyIJBSQ8Xw';

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Content-Type': 'application/json'
  };
  const deny = (statusCode, error) => ({ statusCode, headers, body: JSON.stringify({ error }) });

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  // ── 1. caller's token ──
  const h = event.headers || {};
  const authHeader = h.authorization || h.Authorization || '';
  const token = /^Bearer\s+(.+)$/i.test(authHeader) ? authHeader.replace(/^Bearer\s+/i, '').trim() : '';
  if (!token) return deny(401, 'Sign in required');

  // ── 2. verify it with Supabase ──
  let userId;
  try {
    const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` }
    });
    if (!who.ok) return deny(401, 'Invalid or expired session');
    const user = await who.json();
    userId = user && user.id;
    if (!userId) return deny(401, 'Invalid or expired session');
  } catch (err) {
    console.error('[wise proxy] auth check failed:', err.message);
    return deny(503, 'Could not verify session');
  }

  // ── 3. role, read from the database ──
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  let role;
  try {
    const readKey = serviceKey || SUPABASE_ANON_KEY;
    const readAs = serviceKey || token;           // service role, else the caller (RLS: own row)
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/staff?select=role&id=eq.${encodeURIComponent(userId)}`,
      { headers: { apikey: readKey, Authorization: `Bearer ${readAs}` } }
    );
    if (res.status === 404) {
      // staff table not created yet (migrations/2026-09-11-staff-roles.sql).
      // Same fallback as the client before that migration runs: any signed-in
      // user counts as admin. Remove once the table exists.
      console.warn('[wise proxy] staff table missing — treating signed-in user as admin');
      role = 'admin';
    } else if (!res.ok) {
      console.error('[wise proxy] staff lookup HTTP', res.status);
      return deny(503, 'Could not check your access level');
    } else {
      const rows = await res.json();
      role = Array.isArray(rows) && rows[0] ? rows[0].role : null;
    }
  } catch (err) {
    console.error('[wise proxy] staff lookup failed:', err.message);
    return deny(503, 'Could not check your access level');
  }
  if (role !== 'admin') return deny(403, 'Admin access required');

  // ── 4. path allow-list (unchanged) ──
  const WISE_TOKEN = process.env.WISE_API_TOKEN;
  if (!WISE_TOKEN) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: 'API token not configured' }) };
  }

  const qs = event.queryStringParameters || {};
  const path = qs.path || '';
  const debug = qs.debug === '1';

  // Accept any path that targets one of the documented Wise profile/account namespaces.
  // The `path` param can include its own query string (e.g. "?since=...&size=50") — it
  // is passed through verbatim to api.wise.com.
  const allowedPrefixes = ['v1/profiles', 'v3/profiles', 'v4/profiles', 'v1/borderless-accounts'];
  const isAllowed = allowedPrefixes.some(p => path.startsWith(p));
  if (!isAllowed) {
    return { statusCode: 403, headers, body: JSON.stringify({ error: 'Path not allowed' }) };
  }

  try {
    const url = `https://api.wise.com/${path}`;
    const resp = await fetch(url, {
      headers: { 'Authorization': `Bearer ${WISE_TOKEN}` }
    });
    const text = await resp.text();
    let data;
    try { data = JSON.parse(text); } catch (_) { data = text; }

    // Diagnostic: surface the shape of the first item in the response to Netlify
    // function logs so we can see what Wise is actually returning. Full sample is
    // only logged when `debug=1` is passed to keep normal logs quiet.
    try {
      const firstItem =
        (data && Array.isArray(data.activities) && data.activities[0]) ||
        (data && Array.isArray(data.transactions) && data.transactions[0]) ||
        (Array.isArray(data) && data[0]) ||
        null;
      if (firstItem && typeof firstItem === 'object') {
        console.log('[wise proxy] status=%d path=%s firstKeys=%j',
          resp.status, path, Object.keys(firstItem));
        if (debug) {
          console.log('[wise proxy] firstItem=', JSON.stringify(firstItem).slice(0, 4000));
        }
      }
    } catch (_) {}

    return {
      statusCode: resp.status,
      headers,
      body: typeof data === 'string' ? data : JSON.stringify(data)
    };
  } catch (err) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
