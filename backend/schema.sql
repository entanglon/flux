-- Flux backend schema (D1 / SQLite)

CREATE TABLE IF NOT EXISTS users (
    id         TEXT PRIMARY KEY,
    email      TEXT UNIQUE NOT NULL,
    pass_hash  TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at);

-- One JSON blob per user containing {watchlist, history, collections, settings}
CREATE TABLE IF NOT EXISTS user_data (
    user_id    TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    payload    TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Login throttling
CREATE TABLE IF NOT EXISTS auth_attempts (
    email      TEXT NOT NULL,
    ip         TEXT NOT NULL,
    ts         INTEGER NOT NULL,
    ok         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_attempts_email_ts ON auth_attempts(email, ts);
