# frozen_string_literal: true

require 'bigdecimal'
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
    def income(from, to)
      query("SELECT account, SUM(position) AS total WHERE date >= #{from.iso8601} AND date <= #{to.iso8601} " \
            "AND account ~ '^(Income|Expenses)' GROUP BY account")
    end

    # Assets, Liabilities and Equity at market value on `at`. Income and Expenses
    # up to that day fold, negated, into one equity row, so the sheet carries its earnings.
    def balance(at)
      rows = query("SELECT account, VALUE(SUM(position), #{at.iso8601}) AS total " \
                   "WHERE date <= #{at.iso8601} GROUP BY account")
      sheet, earned = rows.partition { |account, _| account.start_with?('Assets', 'Liabilities', 'Equity') }
      earnings = Hash.new(BigDecimal('0'))
      earned.each { |(_, amounts)| amounts.each { |currency, number| earnings[currency] -= number } }
      sheet.to_h.merge(EARNINGS => earnings)
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
