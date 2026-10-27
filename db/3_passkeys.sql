-- The passkeys (WebAuthn credentials) of each user. id is the credential id in base64url,
-- as the browser sends it. public_key is SubjectPublicKeyInfo DER: ES256 or RS256.

CREATE TABLE passkeys (
  id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users (id),
  public_key BLOB NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);
