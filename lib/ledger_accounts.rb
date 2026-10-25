# frozen_string_literal: true

module Frijolero
  # The accounts a posting can use, for the autocomplete and the new-account form.
  module LedgerAccounts
    OPEN = /^\d{4}-\d{2}-\d{2} open (\S+)/
    CLOSE = /^\d{4}-\d{2}-\d{2} close (\S+)/

    # Opened and not closed: a name only a rule uses, or a closed account, would fail the
    # ledger check. ponytail: an account closed and opened again counts as closed.
    def self.active
      (text.scan(OPEN) - text.scan(CLOSE)).flatten.uniq.sort
    end

    # The files that rledger reads. A ledger that LedgerFiles refuses offers none: the badge says why.
    def self.text
      LedgerFiles.all.map { |f| File.read(f) }.join("\n")
    rescue LedgerFiles::Unsafe
      ''
    end
  end
end
