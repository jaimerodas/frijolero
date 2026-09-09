# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require 'json'
require 'open3'

module Frijolero
  # Whole-ledger reports through rustledger: one BQL query per page, JSON back.
  # The binary only reads the ledger. Dates arrive as Date objects, so nothing
  # from the request reaches the query string unparsed.
  module Reports
    class Error < StandardError; end

    EARNINGS = 'Equity:Utilidades-acumuladas'

    module_function

    # Income and Expenses postings in [from, to]: {account => {currency => BigDecimal}}.
    # With `mxn`, every posting is restated at the closing rate of the period.
    def income(from, to, mxn: true)
      total = mxn ? in_mxn(to) : 'SUM(position)'
      query("SELECT account, #{total} AS total WHERE date >= #{from.iso8601} AND date <= #{to.iso8601} " \
            "AND account ~ '^(Income|Expenses)' GROUP BY account")
    end

    # Assets, Liabilities and Equity at market value on `at`. Income and Expenses
    # up to that day fold, negated, into one equity row, so the sheet carries its earnings.
    def balance(at, mxn: true)
      total = mxn ? in_mxn(at) : "VALUE(SUM(position), #{at.iso8601})"
      rows = query("SELECT account, #{total} AS total WHERE date <= #{at.iso8601} GROUP BY account")
      sheet, earned = rows.partition { |account, _| account.start_with?('Assets', 'Liabilities', 'Equity') }
      earnings = Hash.new(BigDecimal('0'))
      earned.each { |(_, amounts)| amounts.each { |currency, number| earnings[currency] -= number } }
      sheet.to_h.merge(EARNINGS => earnings)
    end

    # One row per matching posting, in query order. `prefix` is pre-validated by
    # the caller ('' means every account); `text` is escaped through `bql_text`.
    def journal(prefix, from, to, mxn: true, text: nil)
      bql = journal_query(prefix, from, to, mxn: mxn, text: text)
      JSON.parse(run(bql)).fetch('rows').map { |row| journal_row(row) }
    end

    def journal_query(prefix, from, to, mxn:, text:)
      amount = mxn ? "CONVERT(position, 'MXN', #{to.iso8601})" : 'position'
      bql = "SELECT date, flag, payee, narration, account, other_accounts, filename, #{amount} AS amount " \
            "WHERE date >= #{from.iso8601} AND date <= #{to.iso8601}"
      bql += " AND account ~ '^#{prefix}(:|$)'" unless prefix.empty?
      bql += " AND (payee ~ '#{bql_text(text)}' OR narration ~ '#{bql_text(text)}')" if text && !text.strip.empty?
      bql
    end

    # A journal row, either shape: {account, ...} or a positional array in column order.
    def journal_row(row)
      columns = %w[date flag payee narration account other_accounts filename amount]
      date, flag, payee, narration, account, others, file, amount_value =
        row.is_a?(Hash) ? row.values_at(*columns) : row
      units = amount_value['units'] || amount_value
      { date: Date.iso8601(date), flag: flag, payee: payee, narration: narration, account: account,
        others: others, file: file, amount: { units['currency'] => BigDecimal(units['number']) } }
    end

    # A raw string into a BQL regex literal: escaped, then `'` becomes `.` (a
    # wildcard), because a BQL string cannot contain an escaped quote.
    def bql_text(text)
      Regexp.escape(text).gsub("'", '.')
    end

    # The earliest transaction, for the `all` period and the period menu.
    # A ledger with no transactions yet answers with today.
    def first_date
      row = JSON.parse(run('SELECT MIN(date) AS first')).fetch('rows').first
      value = row.is_a?(Hash) ? row['first'] : row&.first
      value.to_s.empty? ? Date.today : Date.iso8601(value)
    end

    # Market value in MXN at the latest price on or before `date`, stocks via USD.
    # A commodity with no price stays as it is, so it shows in its own column.
    def in_mxn(date)
      "SUM(CONVERT(position, 'MXN', #{date.iso8601}))"
    end

    def query(bql)
      # 0.22 prints each row as {account, total}; 0.24 as [account, total].
      JSON.parse(run(bql)).fetch('rows').to_h do |row|
        account, total = row.is_a?(Hash) ? row.values_at('account', 'total') : row
        [account, total['positions'].to_h { |p| [p['currency'], BigDecimal(p['number'])] }]
      end
    end

    def run(bql)
      out, err, status = Open3.capture3(Config.rledger, 'query', '--no-cache', '-q', '-f', 'json',
                                        Config.report_file, bql)
      return out if status.success?

      raise Error, err.strip.empty? ? "rledger salió con #{status.exitstatus}" : err.strip
    rescue Errno::ENOENT => e
      raise Error, e.message
    end

    # One row per account and per ancestor, in tree order, with the parents
    # carrying the sum of their subtree: {name:, depth:, amounts:, total:}.
    # An account at zero in every currency is left out, as on a printed sheet.
    def tree(flat)
      sums = subtotals(flat.reject { |_, amounts| amounts.values.all?(&:zero?) })
      # ponytail: O(n²) parent check; ~130 accounts.
      sums.keys.sort_by { |k| k.split(':') }.map do |name|
        { name: name, depth: name.count(':'), amounts: sums[name],
          total: sums.keys.any? { |k| k.start_with?("#{name}:") } }
      end
    end

    def subtotals(flat)
      sums = Hash.new { |h, k| h[k] = Hash.new(BigDecimal('0')) }
      flat.each do |account, amounts|
        parts = account.split(':')
        parts.each_index { |i| amounts.each { |cur, n| sums[parts[..i].join(':')][cur] += n } }
      end
      sums
    end
  end
end
