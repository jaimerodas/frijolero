-- signin_tokens again, with created_at: the rate limit counts the links of the last hour.
-- No row existed yet, so the drop loses nothing.

DROP TABLE signin_tokens;

-- A sign-in link, by the SHA-256 of its token. An invitation is one that lives longer.
CREATE TABLE signin_tokens (
  token_sha256 TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users (id),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT
);
