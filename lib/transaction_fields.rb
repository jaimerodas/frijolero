# frozen_string_literal: true

module Frijolero
  # Campos, the edit dialog's form, on the text of one transaction: what the form shows, and the
  # text that its save writes. The dialog's other tab, the text itself, is LedgerEdit's alone.
  module TransactionFields
    # An `event` or a `query` also has a header of two strings.
    FLAG = /\A(?:[*!]|txn)\z/

    module_function

    # { flag:, payee:, narration:, description:, source_desc:, postings: [{ index:, account:, rest: }] },
    # where `index` is the posting's line in the text and `rest` what follows its account. Nil for any
    # other directive, and for a header that Beancount::Header cannot rewrite: the dialog then has only the text.
    def of(text)
      transaction = parse(text)
      return unless transaction.parsed? && transaction.flag.match?(FLAG)

      { flag: transaction.flag, payee: transaction.payee.to_s, narration: transaction.narration.to_s,
        description: transaction.description.to_s, source_desc: transaction.metadata.key?('source_desc'),
        postings: transaction.postings.map { |posting| posting_fields(text, posting) } }
    end

    # `text` with what Campos sent: the accounts, { index => account }, then the payee and the narration.
    # A field as it was, or an empty account, changes nothing; an empty payee removes it.
    # Transaction#apply keeps the first narration in `source_desc`, as the rules do.
    def apply(text, payee:, narration:, accounts:)
      transaction = parse(text.to_s.gsub("\r\n", "\n"))
      if transaction.parsed?
        apply_accounts(transaction, accounts)
        apply_header(transaction, payee: payee, narration: narration)
      end
      transaction.block[:lines].join
    end

    def parse(text) = Beancount::Transaction.new(lines: text.lines)

    def posting_fields(text, posting)
      { index: posting[:index], account: posting[:account],
        rest: text.lines[posting[:index]].strip.delete_prefix(posting[:account]).strip }
    end

    def apply_accounts(transaction, accounts)
      current = transaction.postings.to_h { |posting| [posting[:index], posting[:account]] }
      accounts.each do |index, account|
        account = account.to_s.strip
        next if account.empty? || [nil, account].include?(current[index.to_i])

        transaction.apply(account: account, posting_index: index.to_i)
      end
    end

    # Only what changed: Transaction#apply records `source_desc` for any narration that it gets.
    def apply_header(transaction, **fields)
      changed = fields.reject { |name, value| value.nil? || value == transaction.public_send(name).to_s }
      transaction.apply(**changed.transform_values(&:strip)) unless changed.empty?
    end

    private_class_method :parse, :posting_fields, :apply_accounts, :apply_header
  end
end
