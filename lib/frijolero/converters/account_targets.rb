# frozen_string_literal: true

module Frijolero
  module Converters
    class AccountTargets
      DEFAULT_GAINS = 'Income:FIXME'

      attr_reader :counterpart, :interest, :tax, :dividend, :gains, :fees, :withholding

      def self.from_config(config)
        config ||= {}
        new(
          counterpart: config['counterpart_account'],
          interest: config['interest_account'],
          tax: config['tax_account'],
          dividend: config['dividend_account'],
          gains: config['gains_account'],
          fees: config['fees_account'],
          withholding: config['withholding_account']
        )
      end

      # `tax` is the local (ISR) withholding account; `withholding` is for
      # foreign tax withheld at source, which Plata reports separately.
      def initialize(counterpart: nil, interest: nil, tax: nil, dividend: nil, gains: nil,
                     fees: nil, withholding: nil)
        @counterpart = counterpart
        @interest = interest
        @tax = tax
        @dividend = dividend
        @gains = gains || DEFAULT_GAINS
        @fees = fees
        @withholding = withholding
      end
    end
  end
end
