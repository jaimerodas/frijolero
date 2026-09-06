# frozen_string_literal: true

module Frijolero
  module Converters
    class AccountTargets
      DEFAULT_GAINS = 'Income:FIXME'

      attr_reader :counterpart, :interest, :tax, :dividend, :gains, :fees, :withholding,
                  :opening

      CONFIG_KEYS = {
        counterpart: 'counterpart_account', interest: 'interest_account',
        tax: 'tax_account', dividend: 'dividend_account', gains: 'gains_account',
        fees: 'fees_account', withholding: 'withholding_account',
        opening: 'opening_account'
      }.freeze

      def self.from_config(config)
        config ||= {}
        new(**CONFIG_KEYS.transform_values { |key| config[key] })
      end

      # `tax` is the local (ISR) withholding account; `withholding` is for
      # foreign tax withheld at source, which Plata reports separately.
      # `opening` receives positions transferred in, which arrive from another
      # broker rather than from anywhere in this ledger.
      def initialize(counterpart: nil, interest: nil, tax: nil, dividend: nil, gains: nil,
                     fees: nil, withholding: nil, opening: nil)
        @counterpart = counterpart
        @interest = interest
        @tax = tax
        @dividend = dividend
        @gains = gains || DEFAULT_GAINS
        @fees = fees
        @withholding = withholding
        @opening = opening
      end
    end
  end
end
