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

  const path = event.queryStringParameters.path || '';
  const allowed = ['v1/profiles', 'v4/profiles', 'v1/borderless-accounts', 'v3/profiles'];
  const isAllowed = allowed.some(a => path.startsWith(a)) || path.match(/^v1\/profiles\/\d+\/balance/) || path.match(/^v3\/profiles\/\d+\/borderless-accounts/) || path.match(/^v1\/borderless-accounts\/\d+\/statement/);

  if (!isAllowed && !path.startsWith('v1/profiles') && !path.startsWith('v4/profiles') && !path.startsWith('v3/profiles')) {
    return { statusCode: 403, headers, body: JSON.stringify({ error: 'Path not allowed' }) };
  }

  try {
    const url = `https://api.wise.com/${path}`;
    const resp = await fetch(url, {
      headers: { 'Authorization': `Bearer ${WISE_TOKEN}` }
    });
    const data = await resp.json();
    return { statusCode: resp.status, headers, body: JSON.stringify(data) };
  } catch (err) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
