# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'time'

module Frijolero
  # The bearer tokens of /api/, the door of the iOS Shortcut. A token names its ledger,
  # and an upload goes to that ledger. As with Signin, a token is 32 random bytes and the
  # database keeps only their SHA-256, so a copy of the database opens nothing. The rows
  # come back as hashes: token_sha256 (the id for revoking), name and last_used_at.
  module ApiTokens
    class << self
      # The raw token. The caller shows it once; nothing keeps it.
      def create(ledger_id, name)
        raw = SecureRandom.urlsafe_base64(32)
        DB.execute('INSERT INTO api_tokens (token_sha256, ledger_id, name) VALUES (?, ?, ?)',
                   digest(raw), ledger_id, name)
        raw
      end

      def for_ledger(ledger_id)
        DB.execute('SELECT token_sha256, name, last_used_at FROM api_tokens WHERE ledger_id = ? ORDER BY rowid',
                   ledger_id)
      end

      # The ledger in the WHERE, so a ledger cannot revoke the token of another.
      def revoke(ledger_id, token_sha256)
        DB.execute('DELETE FROM api_tokens WHERE ledger_id = ? AND token_sha256 = ?', ledger_id, token_sha256)
      end

      # The ledger id of the token, or nil, and the token records its use. The owner of
      # the ledger must be active: a blocked user keeps no door, because an upload can
      # cost a model call.
      def ledger_id_for(raw, now: Time.now)
        DB.first('UPDATE api_tokens SET last_used_at = ? WHERE token_sha256 = ? AND ledger_id IN ' \
                 '(SELECT ledgers.id FROM ledgers JOIN users ON users.id = ledgers.owner_id ' \
                 "WHERE users.status = 'active') RETURNING ledger_id", now.getutc.iso8601, digest(raw))
          &.fetch('ledger_id')
      end

      private

      def digest(raw) = Digest::SHA256.hexdigest(raw.to_s)
    end
  end
end
