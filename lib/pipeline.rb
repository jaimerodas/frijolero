# frozen_string_literal: true

module Frijolero
  module Pipeline
    # An extraction is a model's account of what the PDF said, and the converters
    # trust it: a missing key surfaces either as a crash halfway through writing the
    # ledger or, worse, as a file that quietly lost a transaction. Each strategy
    # states the minimum its own converter needs, so the job can stop before anything
    # is written and before the local PDF is deleted.
    class InvalidData < StandardError; end

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

      def validate!(data)
        raise InvalidData, 'the response is not a JSON object' unless data.is_a?(Hash)
      end

      # The extraction request, as loaded from config/prompts. A strategy may shape it.
      def request_spec(spec)
        spec
      end

      private

      # Every strategy's check is the same shape: a top-level array of row hashes,
      # each carrying the keys its converter reads without a fallback. A `required`
      # entry may itself be an array, meaning the converter accepts any one of them.
      def validate_rows!(data, key, required = [])
        rows = data[key]
        raise InvalidData, "#{key} is not an array" unless rows.is_a?(Array)

        rows.each_with_index { |row, index| validate_row!(row, "#{key}[#{index}]", required) }
      end

      def validate_row!(row, label, required)
        raise InvalidData, "#{label} is not an object" unless row.is_a?(Hash)

        missing = required.find { |field| Array(field).none? { |name| row[name] } }
        raise InvalidData, "#{label} lacks #{Array(missing).join(' or ')}" if missing
      end
    end

    class Default < Base
      # Converters::Default fetches date and amount, so it raises without them, and
      # falls back to a blank description — but a row with no description is a bad
      # read rather than a valid transaction, so it counts as required too.
      REQUIRED = %w[date description amount].freeze

      def runs_detailer?
        true
      end

      def validate!(data)
        super
        validate_rows!(data, 'transactions', REQUIRED)
      end

      def summary(data)
        list = data['transactions'] || []
        "Found #{list.size} transactions#{Log.transaction_summary(list)}"
      end

      def convert(json_path:, output: nil, account: beancount_account, expense_account: nil, **)
        kwargs = { input: json_path, account: account, output: output }
        kwargs[:expense_account] = expense_account if expense_account
        Converters::Default.convert(**kwargs)
      end
    end

    # One PDF that covers several accounts of the same bank, each in its own
    # "Movimientos de <name>" section. `accounts` in accounts.yaml maps the printed
    # name to a Beancount account; the model only ever sees the names, as an enum,
    # and each row posts from the account its section names.
    class Multi < Default
      def accounts
        @account_config['accounts'] || {}
      end

      def request_spec(spec)
        spec = Marshal.load(Marshal.dump(spec))
        spec['format']['schema']['properties']['transactions']['items']['properties']['account']['enum'] = accounts.keys
        spec
      end

      def validate!(data)
        super
        validate_rows!(data, 'transactions', ['account'])
        data['transactions'].each_with_index do |row, index|
          next if accounts.key?(row['account'])

          raise InvalidData,
                "transactions[#{index}] account '#{row['account']}' is not in accounts: #{accounts.keys.join(', ')}"
        end
      end

      def convert(json_path:, output: nil, account: beancount_account, **)
        Converters::Default.convert(input: json_path, account: account, output: output, sources: accounts)
      end
    end

    class CetesDirecto < Base
      # The converter dispatches on movement_type (an unknown one is dropped without
      # a sound) and dates each posting with settlement_date, falling back to
      # trade_date. The cash columns go through to_f, and a row legitimately carries
      # only the one of them that applies.
      REQUIRED = ['movement_type', %w[settlement_date trade_date]].freeze

      def validate!(data)
        super
        validate_rows!(data, 'movements', REQUIRED)
      end

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
      # Fintual's rows are not named like the default converter's: it dispatches on
      # transaction_type, dates on trade_date and takes its money from
      # reported_amount. description is optional — every handler has a Spanish default.
      REQUIRED = %w[trade_date transaction_type reported_amount].freeze

      def validate!(data)
        super
        validate_rows!(data, 'transactions', REQUIRED)
      end

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

    class Plata < Base
      # An Alpaca statement spreads its movements over four tables, so counting one
      # of them under-reports badly. Entry.stream is what the converter itself walks,
      # so this counts exactly what will reach the ledger — sweep rows, which are
      # internal transfers the converter drops, are reported separately.
      # The four detail tables Entry.stream merges, plus the holdings that become the
      # price directives, the balance assertions and the opens and closes. Rows are
      # not checked field by field: Entry deliberately skips a row with no date (the
      # extractor is told to warn rather than invent one) and every figure goes
      # through to_d, so an absent column is a zero and not a crash.
      TABLES = %w[transactions income fees deposits_withdrawals holdings].freeze

      def validate!(data)
        super
        TABLES.each { |key| validate_rows!(data, key) }
      end

      def summary(data)
        entries = Converters::Plata::Entry.stream(data)
        sweeps = entries.count { |entry| entry.entry_type == Converters::Plata::SWEEP }
        parts = [pluralize(entries.size - sweeps, 'movement')]
        parts << "#{pluralize(sweeps, 'cash sweep')} ignored" if sweeps.positive?
        "Found #{parts.join(', ')}"
      end

      def convert(json_path:, output: nil, account: beancount_account, **)
        Converters::Plata.convert(
          input: json_path,
          account: account,
          output: output,
          targets: Converters::AccountTargets.from_config(@account_config)
        )
      end

      private

      def pluralize(count, noun)
        "#{count} #{noun}#{'s' unless count == 1}"
      end
    end

    TYPES = {
      'cetes_directo' => CetesDirecto,
      'fintual' => Fintual,
      'multi' => Multi,
      'plata' => Plata
    }.freeze
  end
end
