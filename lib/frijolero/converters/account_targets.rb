# frozen_string_literal: true

module Frijolero
  module Converters
    class AccountTargets
      DEFAULT_GAINS = 'Income:FIXME'

      attr_reader :counterpart, :interest, :tax, :dividend, :gains

      def self.from_config(config)
        config ||= {}
        new(
          counterpart: config['counterpart_account'],
          interest: config['interest_account'],
          tax: config['tax_account'],
          dividend: config['dividend_account'],
          gains: config['gains_account']
        )
      end

      def initialize(counterpart: nil, interest: nil, tax: nil, dividend: nil, gains: nil)
        @counterpart = counterpart
        @interest = interest
        @tax = tax
        @dividend = dividend
        @gains = gains || DEFAULT_GAINS
      end
    end
  end
end
