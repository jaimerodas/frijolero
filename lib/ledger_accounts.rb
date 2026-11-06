# frozen_string_literal: true

module Frijolero
  # The accounts a posting can use, for the autocomplete and the new-account form, and the
  # payees that the ledger already uses, for the payee fields.
  module LedgerAccounts
    OPEN = /^\d{4}-\d{2}-\d{2} open (\S+)/
    CLOSE = /^\d{4}-\d{2}-\d{2} close (\S+)/
    # The first of two strings in a transaction's header.
    PAYEE = /^\d{4}-\d{2}-\d{2}[ \t]+(?:[*!]|txn)[ \t]+"((?:[^"\\]|\\.)*)"[ \t]+"/

    # Opened and not closed: a name only a rule uses, or a closed account, would fail the
    # ledger check. ponytail: an account closed and opened again counts as closed.
    def self.active
      (text.scan(OPEN) - text.scan(CLOSE)).flatten.uniq.sort
    end

    # Each payee once, the most used first: a <datalist> shows them in this order.
    def self.payees
      text.scan(PAYEE).map { |(payee)| Beancount::Quoting.unescape(payee) }.reject(&:empty?)
          .tally.sort_by { |payee, count| [-count, payee] }.map(&:first)
    end

    # The files that rledger reads. A ledger that LedgerFiles refuses offers none: the badge says why.
    def self.text
      LedgerFiles.all.map { |f| File.read(f) }.join("\n")
    rescue LedgerFiles::Unsafe
      ''
    end
  end
end
