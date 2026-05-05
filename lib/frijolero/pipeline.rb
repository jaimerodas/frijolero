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
        Converters::Beancount.convert(**kwargs)
      end
    end

    class CetesDirecto < Base
      def summary(data)
        list = data['movements'] || []
        "Found #{list.size} movements"
      end

      def convert(json_path:, output: nil, account: beancount_account, **)
        Converters::CetesDirecto.convert(
          input: json_path,
          account: account,
          output: output,
          targets: Converters::AccountTargets.from_config(@account_config)
        )
      end
    end

    class Fintual < Base
      def summary(data)
        list = data['transactions'] || []
        "Found #{list.size} transactions"
      end

      def convert(json_path:, output: nil, account: beancount_account, **)
        Converters::Fintual.convert(
          input: json_path,
          account: account,
          output: output,
          targets: Converters::AccountTargets.from_config(@account_config)
        )
      end
    end

    TYPES = {
      'cetes_directo' => CetesDirecto,
      'fintual' => Fintual
    }.freeze
  end
end
