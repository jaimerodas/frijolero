# frozen_string_literal: true

require 'date'
require 'json'

module Frijolero
  # The `balance` line at the end of a Default or Multi statement, from the closing balance that
  # the PDF prints. 22 AMEX statements (November 2026) showed why it is not the day after the
  # close: the next statement can hold a charge dated on the closing day, and in 3 of 20 months
  # one dated a few days before it (an Amazon charge billed a month late). So the line goes on
  # the closing day, which Beancount checks before that day's rows, and takes out this
  # statement's own rows of that day or later. A row of the next statement dated before the
  # close goes into the line when that statement arrives. Each term stays written out, so the
  # PDF's number is in sight (docs/ledger.md, "Los saldos").
  module StatementBalance
    MARK = '; El saldo al corte del PDF, contado antes del día del corte (docs/ledger.md)'

    extend Converters::Amounts

    class << self
      # Appends the balance of `period` to its file. When this statement holds rows dated
      # before the close of the one before it, that statement's line is written again. The
      # first statement of an account has no cutoff_day yet: the job records it after this.
      def write(key, period, config)
        return Log.puts('No balance line: the account has no cutoff_day yet') unless config['cutoff_day']

        lines = lines(key, period, config)
        File.write(path(key, period), block(lines), mode: 'a') if lines.any?
        lines.each { |line| Log.puts "Balance: #{line}" }
        previous = shift(period, -1)
        rewrite(key, previous, config) if early_rows?(key, period, previous, config)
      end

      private

      # The balance lines of one statement: none without a JSON or a printed balance.
      def lines(key, period, config)
        data = json(key, period)
        return [] unless data

        day = closing(period, config)
        terms = terms(key, period, data, day, config)
        closings(data, config).map do |account, closing|
          signed = terms.filter_map { |t| t[account] }.reject(&:zero?)
          "#{day} balance #{account}  #{money(closing)}#{signed.map { |t| term(t) }.join} MXN"
        end
      end

      # What the line adds to the printed balance, one entry per row: this statement's rows of
      # the closing day or later come out, and the next statement's rows dated before it go in.
      def terms(key, period, data, day, config)
        own = effects_where(data, config) { |date| date >= day }
        later = effects_where(json(key, shift(period, 1)) || {}, config) { |date| date < day }
        own.map { |effects| effects.transform_values(&:-@) } + later
      end

      def term(amount) = amount.negative? ? " - #{money(-amount)}" : " + #{money(amount)}"

      def shift(period, months) = (Date.strptime(period, '%y%m') >> months).strftime('%y%m')

      def block(lines) = "#{MARK}\n#{lines.join("\n")}\n"

      def path(key, period) = Config.statement_path(key, period, 'beancount')

      def json(key, period)
        file = Config.statement_path(key, period, 'json')
        JSON.parse(File.read(file)) if File.exist?(file)
      end

      def closing(period, config) = AccountConfig.closing(period, config['cutoff_day'])

      # {account => the printed closing balance}. Multi prints one per section.
      def closings(data, config)
        pairs = if data.key?('closing_balances')
                  data['closing_balances'].map { |b| [config.dig('accounts', b['account']), b['amount']] }
                else
                  [[config['beancount_account'], data['closing_balance']]]
                end
        pairs.reject { |account, amount| account.nil? || amount.nil? }.map { |account, amount| [account, to_d(amount)] }
      end

      # The effects of the rows whose date the block takes.
      def effects_where(data, config)
        Array(data['transactions']).filter_map { |row| effects(row, config) if yield(Date.parse(row['date'])) }
      end

      # {account => amount} for one row: its section's account, and in a Multi the other
      # account of an internal move that a rule named.
      def effects(row, config)
        amount = to_d(row['amount'])
        source = config.dig('accounts', row['account']) || config['beancount_account']
        effects = { source => amount }
        other = row['expense_account']
        effects[other] = effects.fetch(other, 0) - amount if config.fetch('accounts', {}).value?(other)
        effects
      end

      def early_rows?(key, period, previous, config)
        day = closing(previous, config)
        file = path(key, previous)
        return false unless File.exist?(file) && File.read(file).include?(MARK)

        effects_where(json(key, period) || {}, config) { |date| date < day }.any?
      end

      # The block that `write` appended goes, and the new one goes at the end of the file.
      def rewrite(key, period, config)
        file = path(key, period)
        text = File.read(file).sub(/^#{Regexp.escape(MARK)}\n(?:\d{4}-\d{2}-\d{2} balance .*\n?)*/, '')
        lines = lines(key, period, config)
        File.write(file, lines.any? ? "#{text}#{block(lines)}" : text)
        lines.each { |line| Log.puts "Balance of #{key} #{period}, with the rows dated before its close: #{line}" }
      end
    end
  end
end
