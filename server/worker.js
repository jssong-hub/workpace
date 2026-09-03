/**
 * 임대지기 계약서 판독 서버 (Cloudflare Workers, 무료 플랜)
 * - 앱(GitHub Pages)에서 계약서 사진(base64)을 받아 Google Gemini(무료 티어)로 읽고 JSON을 돌려준다.
 * - API 키는 이 서버의 Secret(GEMINI_API_KEY)에만 저장되며 앱/폰에는 노출되지 않는다.
 *
 * 환경 변수(Settings → Variables and Secrets)
 *   GEMINI_API_KEY   (Secret, 필수)  Google AI Studio에서 발급한 키
 *   GEMINI_MODEL     (선택) 기본 gemini-2.5-flash
 *   ALLOWED_ORIGINS  (선택) 허용할 앱 주소, 쉼표 구분. 예: https://jssong-hub.github.io
 *                    비워두면 모든 출처 허용(테스트용). 공개 후에는 꼭 지정하세요.
 *   APP_TOKEN        (선택, Secret) 설정하면 앱 설정의 "서버 비밀번호"와 일치해야 처리
 */

const PROMPT = `당신은 한국 부동산 임대차계약서 검토 보조원입니다. 첨부된 계약서 사진(들)을 읽고 아래 JSON만 출력하세요(설명 금지, 코드블록 금지).
{"name":"물건 짧은 이름(예: 테헤란로 상가 101호)","type":"shop|office|house|land|etc","addr":"소재지","area":숫자(㎡, 모르면 null),"tenant":"임차인 성명/상호","tenantPhone":"임차인 연락처 또는 빈문자열","tenantBiz":"임차인 사업자등록번호 또는 빈문자열","tenantBizName":"임차인 상호 또는 빈문자열","deposit":숫자(원),"rent":숫자(원, 월 임대료 공급가액),"mgmt":숫자(원, 관리비, 없으면 0),"vatSeparate":true|false(부가세 별도 명시 여부),"payDay":숫자(매월 납부일),"start":"YYYY-MM-DD","end":"YYYY-MM-DD","memo":"특약사항 요약(200자 이내)",
"review":[{"level":"ok|warn|bad","item":"점검 항목","detail":"근거/제안 (60자 이내)"}]}
review에는 최소 6개 항목: 당사자·물건 특정, 기간·갱신 조항, 보증금·임대료·납부일 명확성, 부가세 별도 표기(상가/사무실), 연체이자·해지 조건, 원상복구·수선 의무, 임대차 신고/확정일자(주택), 특약 위험요소. 금액은 "金 삼천만 원정"처럼 한글·한자로 적혀 있어도 숫자(원)로 환산하세요. 읽을 수 없는 값은 null 또는 빈문자열로 두세요.`;

const MAX_IMAGES = 6;
const MAX_TOTAL_BYTES = 12 * 1024 * 1024; // base64 기준 약 12MB

function cors(origin, env) {
  const allowed = (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
  const ok = !allowed.length || allowed.includes(origin);
  return {
    ok,
    headers: {
      'Access-Control-Allow-Origin': ok ? (origin || '*') : 'null',
      'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
      'Access-Control-Allow-Headers': 'content-type, x-app-token',
      'Access-Control-Max-Age': '86400',
      'Vary': 'Origin',
    },
  };
}
const json = (obj, status, headers) => new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json; charset=utf-8', ...headers } });

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const c = cors(origin, env);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: c.headers });
    if (request.method === 'GET') return json({ ok: true, service: 'rentkeeper-extract', model: env.GEMINI_MODEL || 'gemini-2.5-flash' }, 200, c.headers);
    if (request.method !== 'POST') return json({ error: 'POST만 지원합니다' }, 405, c.headers);
    if (!c.ok) return json({ error: '허용되지 않은 출처입니다' }, 403, c.headers);
    if (env.APP_TOKEN && request.headers.get('x-app-token') !== env.APP_TOKEN) return json({ error: '서버 비밀번호가 맞지 않습니다' }, 401, c.headers);
    if (!env.GEMINI_API_KEY) return json({ error: '서버에 GEMINI_API_KEY가 설정되지 않았습니다' }, 500, c.headers);

    let body;
    try { body = await request.json(); } catch { return json({ error: '요청 형식 오류' }, 400, c.headers); }
    const images = Array.isArray(body.images) ? body.images.slice(0, MAX_IMAGES) : [];
    if (!images.length) return json({ error: '사진이 없습니다' }, 400, c.headers);
    let total = 0;
    const parts = [];
    for (const img of images) {
      const m = /^data:(image\/[a-z+]+);base64,(.+)$/i.exec(String(img));
      const mime = m ? m[1] : 'image/jpeg', data = m ? m[2] : String(img);
      total += data.length;
      if (total > MAX_TOTAL_BYTES) return json({ error: '사진 용량이 너무 큽니다. 장수를 줄여 주세요' }, 413, c.headers);
      parts.push({ inline_data: { mime_type: mime, data } });
    }
    parts.push({ text: PROMPT });

    const model = env.GEMINI_MODEL || 'gemini-2.5-flash';
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
    let r, j;
    try {
      r = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
        body: JSON.stringify({ contents: [{ role: 'user', parts }], generationConfig: { temperature: 0, response_mime_type: 'application/json', max_output_tokens: 2048 } }),
      });
      j = await r.json();
    } catch (e) { return json({ error: '판독 서비스에 연결하지 못했습니다: ' + e.message }, 502, c.headers); }
    if (!r.ok) {
      const msg = j?.error?.message || `Gemini 오류 ${r.status}`;
      const status = r.status === 429 ? 429 : 502;
      return json({ error: r.status === 429 ? '무료 사용량을 잠시 초과했습니다. 1분 후 다시 시도하세요' : msg }, status, c.headers);
    }
    const text = (j.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('');
    let data;
    try { const mm = text.match(/\{[\s\S]*\}/); data = JSON.parse(mm ? mm[0] : text); } catch { return json({ error: '판독 결과를 해석하지 못했습니다', raw: text.slice(0, 500) }, 502, c.headers); }
    return json({ ok: true, data, model }, 200, c.headers);
  },
};
