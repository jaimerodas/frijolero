# frozen_string_literal: true

module Frijolero
  module Converters
    class Plata < Base
      # One row of an Alpaca statement, whichever of the four detail tables it came
      # from. The tables disagree on column names -- "Net Amt" against "Amount" --
      # and the Fees table has no Entry Type column at all, so the converter works
      # against this one shape instead of four near-identical ones.
      Entry = Struct.new(:date, :source, :entry_type, :symbol, :description,
                         :quantity, :price, :amount, :commission, :side,
                         keyword_init: true)

      # `stream` merges the tables into a single date-ordered sequence. The sort is
      # stable and keyed on the printed position, which matters twice: a dividend
      # booked, reversed and rebooked on one date must stay in that order, and the
      # rows of a corporate action must stay adjacent for the converter to group them.
      class << Entry
        include Amounts

        # Statement order, and the tie-break within a date.
        TABLES = [
          ['transactions', :transaction],
          ['income', :income],
          ['fees', :fee],
          ['deposits_withdrawals', :deposit_withdrawal]
        ].freeze

        def stream(json)
          TABLES.each_with_index.flat_map do |(key, source), table|
            rows(json, key).each_with_index.map do |row, position|
              entry = build(row, source)
              entry && [[entry.date, table, position], entry]
            end
          end.compact.sort_by(&:first).map(&:last)
        end

        private

        def rows(json, key)
          value = json[key]
          value.is_a?(Array) ? value : []
        end

        # A row without a date cannot be placed in the ledger at all. The extractor is
        # instructed to warn about such rows rather than invent a date for them.
        def build(row, source)
          date = row['trade_date']
          return nil if date.nil? || date.to_s.empty?

          Entry.new(
            date: date, source: source, entry_type: entry_type(row, source),
            symbol: symbol(row['symbol']), description: row['description'],
            side: row['side'], **figures(row)
          )
        end

        # The Transaction table calls its money column "Amount"; Income, Fees and
        # Deposit & Withdrawals all call theirs "Net Amt".
        def figures(row)
          {
            quantity: to_d(row['quantity']), price: to_d(row['price']),
            amount: to_d(row['amount'] || row['net_amount']),
            commission: to_d(row['commission'])
          }
        end

        # The Fees table has no Entry Type column, and Alpaca appends footnote
        # asterisks to some types ("Cash Interest**").
        def entry_type(row, source)
          return 'Fee' if source == :fee

          row['entry_type'].to_s.sub(/\*+\z/, '').strip
        end

        # Non-security rows print "-" in the Symbol column.
        def symbol(value)
          text = value.to_s.strip
          return nil if text.empty? || text == '-'

          text
        end
      end
    end
  end
end
