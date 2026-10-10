# frozen_string_literal: true

require 'json'

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

      def convert(json_path:, output:)
        Converters::Default.convert(input: json_path, account: beancount_account, output: output)
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

      def convert(json_path:, output:)
        drop_mirrors(json_path)
        Converters::Default.convert(input: json_path, account: beancount_account, output: output, sources: accounts)
      end

      private

      # Both sections print an internal move. A rule that points a row at another
      # account of this statement marks it as the one that stays; the row in that
      # account with the same date and the opposite amount is its mirror and goes.
      def drop_mirrors(json_path)
        data = JSON.parse(File.read(json_path))
        kept = without_mirrors(data['transactions'])
        dropped = data['transactions'].size - kept.size
        return if dropped.zero?

        Log.puts "Dropped #{dropped} mirrored internal transfer(s)"
        File.write(json_path, JSON.pretty_generate(data.merge('transactions' => kept)))
      end

      def without_mirrors(rows)
        rows.each_with_object([]) { |row, kept| kept << row unless kept.any? { |k| mirror?(k, row) } }
      end

      def mirror?(kept, row)
        kept['expense_account'] == accounts[row['account']] && kept['date'] == row['date'] &&
          kept['amount'] == -row['amount']
      end
    end

    class CetesDirecto < Base
      include Converters::Amounts

      # The converter dispatches on movement_type and dates each posting with
      # settlement_date, falling back to trade_date. A row carries only the cash
      # column that applies.
      #
      # It also asserts the cash and every holding, so a bad read would only show as
      # a failed balance after the commit. These checks repeat the statement's own
      # reconciliation first, while the PDF is still there for a retry.
      REQUIRED = ['movement_type', %w[settlement_date trade_date]].freeze
      HANDLED = Converters::CetesDirecto::KINDS.keys + [Converters::CetesDirecto::TAX]

      def validate!(data)
        super
        validate_rows!(data, 'movements', REQUIRED)
        validate_types!(data['movements'])
        validate_titles!(data)
        validate_cash!(data)
      end

      def summary(data)
        list = data['movements'] || []
        "Found #{list.size} movements"
      end

      def convert(json_path:, output:)
        Converters::CetesDirecto.convert(
          input: json_path,
          account: beancount_account,
          output: output,
          targets: Converters::AccountTargets.from_config(@account_config)
        )
      end

      private

      def validate_types!(rows)
        rows.each_with_index do |row, index|
          next if HANDLED.include?(row['movement_type'])

          raise InvalidData, "movements[#{index}] is '#{row['movement_type']}' (#{row['description_code']}), " \
                             'which the converter does not handle'
        end
      end

      # Each security goes from its opening titles to its closing titles.
      def validate_titles!(data)
        reached = reached_titles(data)
        closing = titles(data['closing_holdings'])
        symbol = (reached.keys | closing.keys).find { |key| reached[key] != closing[key] }
        return unless symbol

        raise InvalidData, "the movements leave #{symbol} at #{number(reached[symbol])} titles, " \
                           "not at the #{number(closing[symbol])} of the closing holdings"
      end

      def titles(holdings)
        (holdings || []).each_with_object(Hash.new(0)) do |holding, totals|
          totals[Converters::CetesDirecto.symbol(holding)] = to_d(holding['titles'])
        end
      end

      # The titles of each security after the movements, from the opening holdings.
      def reached_titles(data)
        data['movements'].each_with_object(titles(data['opening_holdings'])) do |row, totals|
          sign = Converters::CetesDirecto::TITLES[row['movement_type']]
          totals[Converters::CetesDirecto.symbol(row)] += sign * to_d(row['titles']) if sign
        end
      end

      # The rows take the cash from "Saldo inicial" to "Saldo final".
      def validate_cash!(data)
        start, finish = data['raw_checks'].to_h.values_at('opening_cash_ledger_balance', 'closing_cash_ledger_balance')
        return if start.nil? || finish.nil?

        reached = data['movements'].sum(to_d(start)) { |row| Converters::CetesDirecto.cash(row) }
        return if reached == to_d(finish)

        raise InvalidData, "the movements take the cash from #{start} to #{number(reached)}, " \
                           "not to the Saldo final of #{finish}"
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

      def convert(json_path:, output:)
        Converters::Fintual.convert(
          input: json_path,
          account: beancount_account,
          output: output,
          targets: Converters::AccountTargets.from_config(@account_config)
        )
      end
    end

    class Alpaca < Base
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
        entries = Converters::Alpaca::Entry.stream(data)
        sweeps = entries.count { |entry| entry.entry_type == Converters::Alpaca::SWEEP }
        parts = [pluralize(entries.size - sweeps, 'movement')]
        parts << "#{pluralize(sweeps, 'cash sweep')} ignored" if sweeps.positive?
        "Found #{parts.join(', ')}"
      end

      def convert(json_path:, output:)
        Converters::Alpaca.convert(
          input: json_path,
          account: beancount_account,
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
      'alpaca' => Alpaca,
      'plata' => Alpaca # the old name, kept for existing ledgers
    }.freeze
  end
end
