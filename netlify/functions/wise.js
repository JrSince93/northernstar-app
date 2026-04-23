exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Type': 'application/json'
  };

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

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
