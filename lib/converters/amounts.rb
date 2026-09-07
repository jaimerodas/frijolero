# frozen_string_literal: true

require 'bigdecimal'

module Frijolero
  module Converters
    # Number parsing and rendering shared by the statement converters.
    #
    # Everything goes through BigDecimal rather than Float: statement figures are
    # decimal quantities, and Float turns an exact reconciliation into a residue
    # like -5.55e-17, which Ruby renders in scientific notation and Beancount's
    # parser rejects outright.
    module Amounts
      private

      # Statement figures arrive as strings with thousands separators, or as nil.
      def to_d(value)
        BigDecimal(value.to_s.delete(','))
      rescue ArgumentError
        BigDecimal(0)
      end

      # 1234567.8 → "1,234,567.80". Beancount reads the commas.
      def money(value)
        group(format('%.2f', to_d(value)))
      end

      # Share counts, rendered without a trailing ".0" and never in exponent form.
      def number(value)
        decimal = to_d(value)
        group(decimal.frac.zero? ? decimal.to_i.to_s : decimal.to_s('F'))
      end

      def group(text)
        text.sub(/\d+/) { |whole| whole.reverse.scan(/\d{1,3}/).join(',').reverse }
      end
    end
  end
end
