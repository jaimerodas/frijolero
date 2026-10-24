-- The first schema. DB runs each db/<n>_*.sql whose <n> is above PRAGMA user_version.
-- Times are ISO 8601 in UTC. Money is an integer of micro-dollars (millionths of a USD).

CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  name TEXT,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  status TEXT NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'active', 'blocked')),
  monthly_cap_micros INTEGER, -- NULL: MONTHLY_CAP_USD
  session_version INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL
);

-- A sign-in link, by the SHA-256 of its token. An invitation is one that lives longer.
CREATE TABLE signin_tokens (
  token_sha256 TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users (id),
  expires_at TEXT NOT NULL,
  used_at TEXT
);

-- The directory of a ledger is DATA_DIR/ledgers/<id>; its clone is repo/ inside it.
-- pdf_prefix is where its PDFs live in the bucket: frijolero/ledgers/<id>, or
-- frijolero for the ledger that the single-user layout had.
CREATE TABLE ledgers (
  id TEXT PRIMARY KEY,
  owner_id INTEGER NOT NULL REFERENCES users (id),
  name TEXT NOT NULL,
  main_file TEXT NOT NULL DEFAULT 'main.beancount',
  pdf_prefix TEXT NOT NULL,
  remote_url TEXT,
  created_at TEXT NOT NULL
);

-- The bearer tokens of /api/ (the iOS Shortcut), by SHA-256. A token names its ledger.
CREATE TABLE api_tokens (
  token_sha256 TEXT PRIMARY KEY,
  ledger_id TEXT NOT NULL REFERENCES ledgers (id),
  name TEXT NOT NULL,
  last_used_at TEXT
);

-- One row per model call. user_id is the owner of the ledger at the time: the owner pays.
-- prompt is the prompt type (classify, default, bbva, ...); cached_tokens are part of input_tokens.
CREATE TABLE usage (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users (id),
  ledger_id TEXT NOT NULL REFERENCES ledgers (id),
  prompt TEXT NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL,
  cost_micros INTEGER NOT NULL,
  at TEXT NOT NULL
);

CREATE INDEX usage_by_user_and_time ON usage (user_id, at);
