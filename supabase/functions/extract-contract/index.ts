// 임대지기 계약서 판독 서버 — Supabase Edge Function (서울 리전)
// 앱에서 계약서 사진(base64)을 받아 AI로 항목을 추출해 돌려준다. 판독 엔진은 비밀값으로 선택:
//   - 데모(무료):  GEMINI_API_KEY 만 등록  → Google Gemini 무료 티어 (카드 불필요)
//   - 실서비스:    UPSTAGE_API_KEY 등록     → Upstage Information Extract (국내 기업, 유료)
//   둘 다 있으면 ENGINE 비밀값(gemini | upstage)으로 지정, 없으면 upstage 우선.
//
// 비밀값(Edge Functions → Secrets):
//   GEMINI_API_KEY    (데모)  https://aistudio.google.com 에서 발급
//   GEMINI_MODEL      (선택)  기본 gemini-2.5-flash
//   UPSTAGE_API_KEY   (실서비스)  https://console.upstage.ai 에서 발급
//   UPSTAGE_ENDPOINT  (선택)  기본 https://api.upstage.ai/v1/information-extraction/chat/completions
//   ENGINE            (선택)  gemini | upstage
//   ALLOWED_ORIGINS   (선택)  허용할 앱 주소, 쉼표 구분. 예: https://jssong-hub.github.io  (비우면 모두 허용)

const UPSTAGE_ENDPOINT = Deno.env.get("UPSTAGE_ENDPOINT") ??
  "https://api.upstage.ai/v1/information-extraction/chat/completions";
const MAX_IMAGES = 6;
const MAX_TOTAL_BASE64 = 12 * 1024 * 1024;

// 계약서에서 뽑을 항목 (Upstage가 이 스키마 그대로 JSON을 채워 준다)
const SCHEMA = {
  type: "object",
  properties: {
    property_name: { type: "string", description: "임대 물건을 짧게 부르는 이름. 예: 테헤란로 152 상가 101호" },
    property_type: { type: "string", description: "물건 유형. shop(상가·점포), office(사무실), house(주택·아파트·오피스텔 주거), land(토지), etc 중 하나" },
    address: { type: "string", description: "임대 물건 소재지 전체 주소" },
    area_m2: { type: "number", description: "임대할 부분(전용) 면적, ㎡ 단위. 평으로만 적혀 있으면 3.3058을 곱해 환산" },
    tenant_name: { type: "string", description: "임차인 성명 또는 상호(법인이면 법인명)" },
    tenant_phone: { type: "string", description: "임차인 연락처(휴대폰). 없으면 빈 문자열" },
    tenant_business_no: { type: "string", description: "임차인 사업자등록번호 000-00-00000. 없으면 빈 문자열" },
    tenant_business_name: { type: "string", description: "임차인 상호(세금계산서용). 없으면 빈 문자열" },
    deposit_krw: { type: "integer", description: "보증금, 원 단위 정수. '金 삼천만 원정' 같은 한글·한자 표기도 숫자로 환산" },
    monthly_rent_krw: { type: "integer", description: "월 임대료(차임) 공급가액, 원 단위 정수. 부가세 포함 표기면 포함 금액 그대로" },
    management_fee_krw: { type: "integer", description: "월 관리비, 원. 없으면 0" },
    vat_separate: { type: "boolean", description: "임대료에 부가가치세 별도라고 명시되어 있으면 true, 포함이거나 언급 없으면 false" },
    rent_pay_day: { type: "integer", description: "매월 임대료 납부일(1~31). 없으면 0" },
    lease_start: { type: "string", description: "임대차 기간 시작일 YYYY-MM-DD (인도일)" },
    lease_end: { type: "string", description: "임대차 기간 종료일 YYYY-MM-DD" },
    special_terms: { type: "string", description: "특약사항 요약, 200자 이내" },
    has_late_interest_clause: { type: "boolean", description: "연체이자 또는 지연손해금 조항이 있는가" },
    has_restoration_clause: { type: "boolean", description: "원상복구(원상회복) 조항이 있는가" },
    has_renewal_clause: { type: "boolean", description: "계약 갱신·연장 조건 조항이 있는가" },
    has_termination_clause: { type: "boolean", description: "해지 조건 조항이 있는가" },
    contract_date: { type: "string", description: "계약 체결일 YYYY-MM-DD. 없으면 빈 문자열" },
  },
  required: ["deposit_krw", "monthly_rent_krw", "lease_start", "lease_end"],
};

function corsHeaders(origin: string) {
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const ok = allowed.length === 0 || allowed.includes(origin);
  return {
    ok,
    headers: {
      "Access-Control-Allow-Origin": ok ? (origin || "*") : "null",
      "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Max-Age": "86400",
      "Vary": "Origin",
    },
  };
}
const json = (obj: unknown, status: number, headers: Record<string, string>) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8", ...headers } });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function callUpstage(images: string[], key: string) {
  const body = {
    model: "information-extract",
    messages: [{ role: "user", content: images.map((url) => ({ type: "image_url", image_url: { url } })) }],
    response_format: { type: "json_schema", json_schema: { name: "lease_contract", schema: SCHEMA } },
  };
  // 동시접속이 많을 때 초당 한도(429)에 걸리면 잠시 기다려 최대 3회 재시도
  for (let attempt = 0; attempt < 4; attempt++) {
    const r = await fetch(UPSTAGE_ENDPOINT, {
      method: "POST",
      headers: { "content-type": "application/json", "authorization": `Bearer ${key}` },
      body: JSON.stringify(body),
    });
    if (r.status === 429 || r.status >= 500) {
      if (attempt === 3) throw new Error(r.status === 429 ? "판독 서비스가 혼잡합니다. 잠시 후 다시 시도해 주세요" : `판독 서비스 오류 ${r.status}`);
      await sleep(600 * Math.pow(2, attempt) + Math.random() * 300);
      continue;
    }
    const j = await r.json();
    if (!r.ok) throw new Error(j?.error?.message ?? j?.message ?? `판독 서비스 오류 ${r.status}`);
    const text = j?.choices?.[0]?.message?.content ?? "";
    const m = String(text).match(/\{[\s\S]*\}/);
    return JSON.parse(m ? m[0] : text);
  }
  throw new Error("판독 실패");
}

const GEMINI_PROMPT = `당신은 한국 부동산 임대차계약서 검토 보조원입니다. 첨부된 계약서 사진(들)을 읽고, 아래 JSON 스키마의 필드를 채운 JSON만 출력하세요(설명·코드블록 금지). 금액은 "金 삼천만 원정"처럼 한글·한자로 적혀 있어도 원 단위 정수로 환산하고, 읽을 수 없는 값은 null 또는 빈 문자열로 두세요.
스키마: ` + JSON.stringify(SCHEMA);

async function callGemini(images: string[], key: string) {
  const model = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
  const parts: any[] = images.map((u) => { const m = /^data:(image\/[a-z+]+);base64,(.+)$/i.exec(u)!; return { inline_data: { mime_type: m[1], data: m[2] } }; });
  parts.push({ text: GEMINI_PROMPT });
  for (let attempt = 0; attempt < 4; attempt++) {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({ contents: [{ role: "user", parts }], generationConfig: { temperature: 0, response_mime_type: "application/json", max_output_tokens: 2048 } }),
    });
    if (r.status === 429 || r.status >= 500) {
      if (attempt === 3) throw new Error(r.status === 429 ? "무료 사용량을 잠시 초과했습니다. 1분 후 다시 시도해 주세요" : `판독 서비스 오류 ${r.status}`);
      await sleep(800 * Math.pow(2, attempt) + Math.random() * 300);
      continue;
    }
    const j = await r.json();
    if (!r.ok) throw new Error(j?.error?.message ?? `판독 서비스 오류 ${r.status}`);
    const text = (j?.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? "").join("");
    const m = String(text).match(/\{[\s\S]*\}/);
    return JSON.parse(m ? m[0] : text);
  }
  throw new Error("판독 실패");
}

function pickEngine(): { name: string; call: (imgs: string[]) => Promise<Record<string, any>> } | null {
  const up = Deno.env.get("UPSTAGE_API_KEY"), gm = Deno.env.get("GEMINI_API_KEY");
  const pref = (Deno.env.get("ENGINE") ?? "").toLowerCase();
  if (pref === "gemini" && gm) return { name: "gemini", call: (i) => callGemini(i, gm) };
  if (pref === "upstage" && up) return { name: "upstage", call: (i) => callUpstage(i, up) };
  if (up) return { name: "upstage", call: (i) => callUpstage(i, up) };
  if (gm) return { name: "gemini", call: (i) => callGemini(i, gm) };
  return null;
}

// 판독 결과 → 앱이 쓰는 형식
function toApp(x: Record<string, any>) {
  const num = (v: unknown) => { const n = Number(String(v ?? "").replace(/[^\d.]/g, "")); return isFinite(n) ? n : 0; };
  const type = ["shop", "office", "house", "land", "etc"].includes(x.property_type) ? x.property_type : "etc";
  const d = {
    name: x.property_name || "", type, addr: x.address || "", area: num(x.area_m2) || null,
    tenant: x.tenant_name || "", tenantPhone: x.tenant_phone || "", tenantBiz: x.tenant_business_no || "", tenantBizName: x.tenant_business_name || "",
    deposit: num(x.deposit_krw), rent: num(x.monthly_rent_krw), mgmt: num(x.management_fee_krw),
    vatSeparate: type === "house" ? false : !!x.vat_separate,
    payDay: Math.min(31, Math.max(0, num(x.rent_pay_day))) || 0,
    start: x.lease_start || "", end: x.lease_end || "", memo: x.special_terms || "",
    review: [] as { level: string; item: string; detail: string }[],
  };
  const ck = (level: string, item: string, detail: string) => d.review.push({ level, item, detail });
  ck(d.tenant ? "ok" : "warn", "당사자·물건 특정", d.tenant ? `임차인 ${d.tenant}` : "임차인 성명을 읽지 못했습니다");
  ck(d.start && d.end ? "ok" : "bad", "임대차 기간", d.start && d.end ? `${d.start} ~ ${d.end}` : "기간을 읽지 못했습니다");
  ck(d.deposit && d.rent ? "ok" : "bad", "보증금·임대료·납부일", d.deposit && d.rent ? `보증금 ${d.deposit.toLocaleString()}원 / 월 ${d.rent.toLocaleString()}원${d.payDay ? ` / 매월 ${d.payDay}일` : " / 납부일 미기재"}` : "금액을 읽지 못했습니다");
  if (type !== "house") ck(x.vat_separate ? "ok" : "warn", "부가세 별도 표기", x.vat_separate ? "부가세 별도 명시 — 세금계산서 발급 대상" : "부가세 별도 문구가 없습니다. 임대료에 포함된 것으로 처리될 수 있어 확인 필요");
  else ck("ok", "과세 구분", "주택임대는 부가가치세 면세 — 세금계산서 발급 대상 아님");
  ck(x.has_late_interest_clause ? "ok" : "warn", "연체이자·해지 조건", x.has_late_interest_clause ? "연체이자 조항 있음" : "연체이자 조항이 보이지 않습니다");
  ck(x.has_restoration_clause ? "ok" : "warn", "원상복구·수선 의무", x.has_restoration_clause ? "원상복구 조항 있음" : "원상복구 조항이 보이지 않습니다");
  ck(x.has_renewal_clause ? "ok" : "warn", "갱신 조건", x.has_renewal_clause ? "갱신 관련 조항 있음" : "갱신 조건 문구가 보이지 않습니다");
  if (type === "house") ck("warn", "임대차 신고·확정일자", "보증금 6천만원 또는 월세 30만원 초과 시 30일 내 임대차 신고 의무(부동산거래신고법). 신고 여부 확인");
  if (!d.tenantBiz && type !== "house") ck("warn", "임차인 사업자번호", "세금계산서 발급에 필요한 사업자등록번호가 없습니다");
  return d;
}

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin") ?? "";
  const c = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: c.headers });
  if (req.method === "GET") return json({ ok: true, service: "rentkeeper-extract", engine: pickEngine()?.name ?? "none" }, 200, c.headers);
  if (req.method !== "POST") return json({ error: "POST만 지원합니다" }, 405, c.headers);
  if (!c.ok) return json({ error: "허용되지 않은 출처입니다" }, 403, c.headers);
  const engine = pickEngine();
  if (!engine) return json({ error: "서버에 판독 키(GEMINI_API_KEY 또는 UPSTAGE_API_KEY)가 설정되지 않았습니다" }, 500, c.headers);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "요청 형식 오류" }, 400, c.headers); }
  const images: string[] = Array.isArray(body?.images) ? body.images.slice(0, MAX_IMAGES) : [];
  if (!images.length) return json({ error: "사진이 없습니다" }, 400, c.headers);
  let total = 0;
  for (const img of images) {
    if (!/^data:image\/[a-z+]+;base64,/i.test(img)) return json({ error: "이미지 형식 오류" }, 400, c.headers);
    total += img.length;
    if (total > MAX_TOTAL_BASE64) return json({ error: "사진 용량이 너무 큽니다. 장수를 줄여 주세요" }, 413, c.headers);
  }

  try {
    let raw: Record<string, any>;
    try { raw = await engine.call(images); }
    catch (e) {
      // 여러 장을 한 번에 받지 못하는 경우: 장별로 읽어 첫 유효값으로 합침
      if (images.length > 1) {
        const parts = await Promise.all(images.map((u) => engine.call([u]).catch(() => ({}))));
        raw = {};
        for (const p of parts) for (const [k, v] of Object.entries(p)) if (raw[k] == null || raw[k] === "" || raw[k] === 0) raw[k] = v;
        if (!Object.keys(raw).length) throw e;
      } else throw e;
    }
    return json({ ok: true, data: toApp(raw), engine: engine.name }, 200, c.headers);
  } catch (e) {
    return json({ error: (e as Error).message || "판독 실패" }, 502, c.headers);
  }
});
