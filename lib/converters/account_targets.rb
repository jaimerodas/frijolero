# frozen_string_literal: true

module Frijolero
  module Converters
    # The accounts a brokerage statement posts to besides its own, from the account's
    # block in accounts.yaml (`<name>_account`, and `payee`). `tax` is the local (ISR)
    # withholding account; `withholding` is for foreign tax withheld at source, which
    # Alpaca reports separately. `opening` receives positions transferred in, which
    # arrive from another broker rather than from anywhere in this ledger. `payee` is
    # the name on every transaction of a brokerage statement.
    AccountTargets = Struct.new(:counterpart, :interest, :tax, :dividend, :gains, :fees, :withholding, :opening,
                                :payee, keyword_init: true) do
      def self.from_config(config)
        new(**members.to_h { |name| [name, (config || {})[name == :payee ? 'payee' : "#{name}_account"]] })
      end

      def gains = self[:gains] || AccountTargets::DEFAULT_GAINS
    end
    AccountTargets::DEFAULT_GAINS = 'Income:FIXME'
  end
end
