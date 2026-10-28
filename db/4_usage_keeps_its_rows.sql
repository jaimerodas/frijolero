-- usage again, without its foreign keys, so a row outlives its ledger and its user. The cap
-- still counts the calls of a deleted ledger, and the costs stay for the totals. Once the
-- user is gone, a row holds no name: an id, a model, tokens and a cost.
-- upload is the token of the upload that the call read (incoming/<token>/). The rows of
-- before this version have none.

CREATE TABLE usage_new (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL,
  ledger_id TEXT NOT NULL,
  upload TEXT,
  prompt TEXT NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL,
  cost_micros INTEGER NOT NULL,
  at TEXT NOT NULL
);

INSERT INTO usage_new (id, user_id, ledger_id, prompt, model, input_tokens, cached_tokens, output_tokens,
                       cost_micros, at)
  SELECT id, user_id, ledger_id, prompt, model, input_tokens, cached_tokens, output_tokens, cost_micros, at
  FROM usage;

DROP TABLE usage;
ALTER TABLE usage_new RENAME TO usage;
CREATE INDEX usage_by_user_and_time ON usage (user_id, at);
