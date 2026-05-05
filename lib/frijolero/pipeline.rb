# frozen_string_literal: true

module Frijolero
  module Pipeline
    def self.for(account_config)
      config = account_config || {}
      klass = TYPES[config['converter_type']] || Default
      klass.new(config)
    end

    class Base
      def initialize(account_config)
        @account_config = account_config || {}
      end

      def beancount_account
        @account_config['beancount_account']
      end

      def runs_detailer?
        false
      end
    end

    class Default < Base
      def runs_detailer?
        true
      end

      def summary(data)
        list = data['transactions'] || []
        "Found #{list.size} transactions#{UI.transaction_summary(list)}"
      end

      def convert(json_path:, output: nil, account: beancount_account, expense_account: nil, **)
        kwargs = { input: json_path, account: account, output: output }
        kwargs[:expense_account] = expense_account if expense_account
        BeancountConverter.convert(**kwargs)
      end
    end

    class CetesDirecto < Base
      def summary(data)
        list = data['movements'] || []
        "Found #{list.size} movements"
      end

      def convert(json_path:, output: nil, account: beancount_account, **)
        CetesDirectoConverter.convert(
          input: json_path,
          account: account,
          output: output,
          counterpart_account: @account_config['counterpart_account'],
          interest_account: @account_config['interest_account'],
          tax_account: @account_config['tax_account'],
          gains_account: @account_config['gains_account'] || CetesDirectoConverter::DEFAULT_GAINS_ACCOUNT
        )
      end
    end

    class Fintual < Base
      def summary(data)
        list = data['transactions'] || []
        "Found #{list.size} transactions"
      end

      def convert(json_path:, output: nil, account: beancount_account, **)
        FintualConverter.convert(
          input: json_path,
          account: account,
          output: output,
          counterpart_account: @account_config['counterpart_account'],
          dividend_account: @account_config['dividend_account'],
          interest_account: @account_config['interest_account'],
          gains_account: @account_config['gains_account'] || FintualConverter::DEFAULT_GAINS_ACCOUNT
        )
      end
    end

    TYPES = {
      'cetes_directo' => CetesDirecto,
      'fintual' => Fintual
    }.freeze
  end
end
