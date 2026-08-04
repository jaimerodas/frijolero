# frozen_string_literal: true

module Frijolero
  module Converters
    # Compares each holding's closing share count against its opening count plus the
    # period's buys and sells. A difference means the share count changed through
    # something the movements table never reported — in practice a stock split.
    #
    # Only holdings still present in the closing portfolio table can be checked: a
    # position sold out entirely disappears from it, leaving nothing to compare.
    class UnitReconciler
      include Amounts

      Mismatch = Struct.new(:ticker, :expected, :reported, :delta, keyword_init: true)

      def initialize(holdings, transactions)
        @holdings = holdings || []
        @transactions = transactions || []
      end

      def mismatches
        @holdings.filter_map { |holding| mismatch_for(holding) }
      end

      private

      def mismatch_for(holding)
        ticker = holding['ticker']
        return nil if ticker.nil?

        reported = to_d(holding['units_current'])
        expected = to_d(holding['units_previous']) + net_traded_units(ticker)
        delta = reported - expected
        return nil if delta.zero?

        Mismatch.new(ticker: ticker, expected: expected, reported: reported, delta: delta)
      end

      def net_traded_units(ticker)
        @transactions.reduce(0) do |total, transaction|
          next total unless transaction['ticker'] == ticker

          case transaction['transaction_type']
          when 'buy' then total + to_d(transaction['units'])
          when 'sell' then total - to_d(transaction['units'])
          else total
          end
        end
      end
    end
  end
end
