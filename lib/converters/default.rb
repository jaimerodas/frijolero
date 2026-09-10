# frozen_string_literal: true

require 'date'

module Frijolero
  module Converters
    class Default < Base
      include Amounts

      DEFAULT_EXPENSE_ACCOUNT = 'Expenses:FIXME'

      # `sources` maps a row's `account` label to the account it posts from; a row
      # without a known label posts from `account`.
      def initialize(expense_account: DEFAULT_EXPENSE_ACCOUNT, sources: {}, **)
        super(**)
        @expense_account = expense_account
        @sources = sources
      end

      def run_to(io)
        load_json.fetch('transactions', []).each { |transaction| io.puts format_transaction(transaction) }
      end

      private

      def format_transaction(transaction)
        date = Date.parse(transaction.fetch('date')).strftime('%Y-%m-%d')
        description = (transaction['description'] || '').gsub(/\s+/, ' ').strip
        narration_provided = transaction['narration']
        amount = transaction.fetch('amount').to_f
        currency = transaction['currency'] || 'MXN'
        expense = transaction['expense_account'] || @expense_account

        lines = [header_line(date, transaction['payee'], narration_provided || description)]
        lines << %(  source_desc: "#{description}") if narration_provided
        source = @sources[transaction['account']] || @account
        lines << "  #{source}  #{money(amount)} #{currency}"
        lines << "  #{expense}"
        lines << ''
        lines.join("\n")
      end

      def header_line(date, payee, narration)
        return %(#{date} * "#{payee}" "#{narration}") if payee

        %(#{date} * "#{narration}")
      end
    end
  end
end
