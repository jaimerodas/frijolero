# frozen_string_literal: true

module Frijolero
  # The rows of a statement page, read from its `.beancount` file, which is what the
  # rules rerun, the edit dialog and fava change; the JSON is frozen at job time. One row
  # per parsed transaction. The source posting is the one on the account, or on one of a
  # Multi's accounts, and gives the amount as the account sees it; the other postings are
  # the classification, and `Expenses:FIXME` among them means unclassified.
  module StatementRows
    module_function

    def read(path, config)
      sources = [config['beancount_account'], *(config['accounts'] || {}).values]
      Beancount::Parser.parse(path).filter_map do |block|
        next unless block[:type] == :transaction

        tx = Beancount::Transaction.new(block)
        row(block[:date], tx, sources) if tx.parsed?
      end
    end

    def row(date, transaction, sources)
      source, others = split(transaction.postings, sources)
      amount, currency = amount_of(source, others)
      { date: date, flag: transaction.flag, description: transaction.description, payee: transaction.payee,
        narration: (transaction.narration if transaction.metadata.key?('source_desc')),
        accounts: others.map { |p| p[:account] }, amount: amount, currency: currency }
    end

    # [source, the rest]; a transaction with no posting on the account takes its first.
    def split(postings, sources)
      source = postings.find { |p| sources.include?(p[:account]) } || postings.first || {}
      [source, postings - [source]]
    end

    # A source posting with its amount elided takes the opposite of the first priced one.
    def amount_of(source, others)
      return [source[:amount], source[:currency]] if source[:amount]

      priced = others.find { |p| p[:amount] }
      priced ? [-priced[:amount], priced[:currency]] : [nil, nil]
    end

    # { currency => [[debits, sum], [credits, sum]] }, the readout the head shows.
    def totals(rows)
      rows.each_with_object({}) do |row, totals|
        next unless row[:amount]

        sides = (totals[row[:currency]] ||= [[0, BigDecimal('0')], [0, BigDecimal('0')]])
        side = sides[row[:amount].negative? ? 0 : 1]
        side[0] += 1
        side[1] += row[:amount]
      end
    end
  end
end
