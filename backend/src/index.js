// Flux backend — Cloudflare Worker + D1.
//
// Identity: Native email/password auth with HMAC-signed JWTs.
// Endpoints:
//   POST /v1/auth/signup    → { uid, email, token }
//   POST /v1/auth/signin    → { uid, email, token }
//   GET  /v1/me             → { user: { uid, email } }
//   GET  /v1/data           → { payload, updatedAt } | { notFound: true }
//   PUT  /v1/data           → { ok }

const DATA_BLOB_LIMIT = 4_000_000;
const PBKDF2_ITERATIONS = 100_000;
const TOKEN_TTL_SECONDS = 30 * 24 * 60 * 60; // 30 days

// Practical RFC-5322-ish check: local@domain.tld (TLD ≥ 2 chars, sane chars only)
const EMAIL_RE = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$/;

function validEmail(email) {
    return typeof email === "string"
        && email.length <= 254
        && !email.includes("..")
        && EMAIL_RE.test(email);
}

const json = (obj, status = 200) =>
    new Response(JSON.stringify(obj), {
        status,
        headers: {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Authorization, Content-Type",
            "Access-Control-Allow-Methods": "GET, PUT, POST, OPTIONS",
        },
    });

const enc = new TextEncoder();
const dec = new TextDecoder();

// ── Password hashing (PBKDF2-SHA256) ──────────────────────────────

async function hashPassword(password, salt) {
    const saltBytes = salt ? base64ToBytes(salt) : crypto.getRandomValues(new Uint8Array(16));
    const keyMaterial = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
    const bits = await crypto.subtle.deriveBits(
        { name: "PBKDF2", salt: saltBytes, iterations: PBKDF2_ITERATIONS, hash: "SHA-256" },
        keyMaterial,
        256
    );
    const hash = bytesToBase64(new Uint8Array(bits));
    const saltStr = bytesToBase64(saltBytes);
    return `${saltStr}:${hash}`;
}

async function verifyPassword(password, stored) {
    const [salt] = stored.split(":");
    const computed = await hashPassword(password, salt);
    return computed === stored;
}

// ── HMAC JWT (HS256) ───────────────────────────────────────────────

async function signJwt(payload, secret) {
    const header = { alg: "HS256", typ: "JWT" };
    const b64 = (obj) => bytesToBase64Url(enc.encode(JSON.stringify(obj)));
    const body = `${b64(header)}.${b64(payload)}`;
    const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
    return `${body}.${bytesToBase64Url(new Uint8Array(sig))}`;
}

async function verifyJwt(token, secret) {
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error("malformed");
    const [header, payload, sigB64] = parts;
    const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const valid = await crypto.subtle.verify("HMAC", key, base64ToBytes(sigB64), enc.encode(`${header}.${payload}`));
    if (!valid) throw new Error("bad_signature");
    const claims = JSON.parse(dec.decode(base64ToBytes(payload)));
    if (claims.exp && claims.exp < Math.floor(Date.now() / 1000)) throw new Error("expired");
    return claims;
}

// ── Base64 helpers ─────────────────────────────────────────────────

function bytesToBase64(bytes) {
    let binary = "";
    for (const b of bytes) binary += String.fromCharCode(b);
    return btoa(binary);
}

function bytesToBase64Url(bytes) {
    return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64ToBytes(b64) {
    const padded = b64.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

// ── Auth helpers ───────────────────────────────────────────────────

async function requireUser(request, env) {
    const auth = request.headers.get("Authorization") || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : null;
    if (!token) return null;
    try {
        return await verifyJwt(token, env.JWT_SECRET);
    } catch {
        return null;
    }
}

// ── Handlers ───────────────────────────────────────────────────────

async function handleSignup(request, env) {
    let body;
    try { body = await request.json(); } catch (_) { return json({ error: "bad_request" }, 400); }
    const email = (body?.email || "").trim().toLowerCase();
    const password = body?.password || "";

    if (!validEmail(email)) return json({ error: "Please enter a valid email address." }, 400);
    if (password.length < 8) return json({ error: "Password too weak (min 8 characters)." }, 400);

    const existing = await env.DB.prepare("SELECT id FROM users WHERE email = ?").bind(email).first();
    if (existing) return json({ error: "That email already has an account." }, 409);

    const uid = crypto.randomUUID();
    const passHash = await hashPassword(password);
    const now = Math.floor(Date.now() / 1000);

    await env.DB.prepare(
        "INSERT INTO users (id, email, pass_hash, created_at) VALUES (?, ?, ?, ?)"
    ).bind(uid, email, passHash, now).run();

    const token = await signJwt({ sub: uid, email, exp: now + TOKEN_TTL_SECONDS }, env.JWT_SECRET);
    return json({ uid, email, token });
}

async function handleSignin(request, env) {
    let body;
    try { body = await request.json(); } catch (_) { return json({ error: "bad_request" }, 400); }
    const email = (body?.email || "").trim().toLowerCase();
    const password = body?.password || "";

    if (!validEmail(email) || !password) return json({ error: "Invalid email or password." }, 400);

    const user = await env.DB.prepare("SELECT id, pass_hash FROM users WHERE email = ?").bind(email).first();
    if (!user) return json({ error: "Invalid email or password." }, 401);

    const ok = await verifyPassword(password, user.pass_hash);
    if (!ok) return json({ error: "Invalid email or password." }, 401);

    const now = Math.floor(Date.now() / 1000);
    const token = await signJwt({ sub: user.id, email, exp: now + TOKEN_TTL_SECONDS }, env.JWT_SECRET);
    return json({ uid: user.id, email, token });
}

async function handleMe(request, env) {
    const user = await requireUser(request, env);
    if (!user) return json({ error: "unauthorized" }, 401);
    return json({ user: { uid: user.sub, email: user.email } });
}

async function handleGetData(request, env) {
    const user = await requireUser(request, env);
    if (!user) return json({ error: "unauthorized" }, 401);

    await env.DB.prepare(
        `INSERT INTO users (id, email, pass_hash, created_at) VALUES (?, ?, '', ?)
         ON CONFLICT(id) DO UPDATE SET email = excluded.email`
    )
        .bind(user.sub, user.email ?? "", Date.now())
        .run();

    const row = await env.DB.prepare(`SELECT payload, updated_at FROM user_data WHERE user_id = ?`)
        .bind(user.sub)
        .first();
    if (!row) return json({ notFound: true, updatedAt: 0 });
    return json({ payload: JSON.parse(row.payload), updatedAt: row.updated_at });
}

async function handlePutData(request, env) {
    const user = await requireUser(request, env);
    if (!user) return json({ error: "unauthorized" }, 401);

    let body;
    try { body = await request.json(); } catch (_) { return json({ error: "bad_request" }, 400); }
    const payload = body?.payload;
    const clientUpdatedAt = Number(body?.updatedAt);
    if (payload === undefined || !Number.isFinite(clientUpdatedAt)) {
        return json({ error: "bad_request" }, 400);
    }
    const serialized = JSON.stringify(payload);
    if (serialized.length > DATA_BLOB_LIMIT) return json({ error: "payload_too_large" }, 413);

    const existing = await env.DB.prepare(`SELECT updated_at FROM user_data WHERE user_id = ?`)
        .bind(user.sub)
        .first();
    if (existing && existing.updated_at >= clientUpdatedAt) {
        return json({ ok: true, superseded: true, updatedAt: existing.updated_at });
    }

    await env.DB.batch([
        env.DB.prepare(
            `INSERT INTO users (id, email, pass_hash, created_at) VALUES (?, ?, '', ?)
             ON CONFLICT(id) DO UPDATE SET email = excluded.email`
        ).bind(user.sub, user.email ?? "", Date.now()),
        env.DB.prepare(
            `INSERT INTO user_data (user_id, payload, updated_at) VALUES (?, ?, ?)
             ON CONFLICT(user_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at`
        ).bind(user.sub, serialized, clientUpdatedAt),
    ]);
    return json({ ok: true, updatedAt: clientUpdatedAt });
}

// ── Router ─────────────────────────────────────────────────────────

export default {
    async fetch(request, env) {
        if (request.method === "OPTIONS") return json({ ok: true });

        const url = new URL(request.url);
        const path = url.pathname.replace(/\/+$/, "");

        try {
            if (request.method === "POST" && path === "/v1/auth/signup")
                return await handleSignup(request, env);
            if (request.method === "POST" && path === "/v1/auth/signin")
                return await handleSignin(request, env);
            if (request.method === "GET" && path === "/v1/me")
                return await handleMe(request, env);
            if (request.method === "GET" && path === "/v1/data")
                return await handleGetData(request, env);
            if (request.method === "PUT" && path === "/v1/data")
                return await handlePutData(request, env);

            return json({ error: "not_found" }, 404);
        } catch (err) {
            console.error("worker error", err);
            return json({ error: "internal" }, 500);
        }
    },
};
