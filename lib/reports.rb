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
    UNREALIZED = 'Equity:Ganancias-no-realizadas'
    CONVERSIONS = 'Equity:Conversiones'
    # Rows the balance sheet makes up. They are not accounts, so no journal.
    SYNTHETIC = [EARNINGS, UNREALIZED, CONVERSIONS].freeze

    module_function

    # Income and Expenses postings in [from, to]: {account => {currency => BigDecimal}}.
    # With `mxn`, every posting is restated at the closing rate of the period.
    def income(from, to, mxn: true)
      total = mxn ? valued(to, true) : 'SUM(position)'
      query("SELECT account, #{total} AS total WHERE date >= #{from.iso8601} AND date <= #{to.iso8601} " \
            "AND account ~ '^(Income|Expenses)' GROUP BY account")
    end

    # Assets, Liabilities and Equity at market value on `at`, in the ledger's own
    # signs (a credit is negative; the view flips Equity). Three made-up equity rows
    # make Assets - Liabilities = Equity hold: Income and Expenses up to that day as
    # retained earnings, cost over market of the assets as unrealized gains, and
    # whatever is left as conversions, which is old cross-currency postings restated
    # at the rate of `at`. Two queries: market value, and cost of the assets.
    def balance(at, mxn: true)
      rows = query("SELECT account, #{valued(at, mxn)} AS total WHERE date <= #{at.iso8601} GROUP BY account")
      at_cost = query("SELECT account, #{valued(at, mxn, cost: true)} AS total WHERE date <= #{at.iso8601} " \
                      "AND account ~ '^Assets' GROUP BY account")
      sheet, earned = rows.partition { |account, _| account.start_with?('Assets', 'Liabilities', 'Equity') }
      sheet.to_h.merge(synthetic_rows(sheet.to_h, earned.to_h, at_cost))
    end

    def synthetic_rows(sheet, earned, at_cost)
      assets = sheet.select { |account, _| account.start_with?('Assets') }.values
      rows = { EARNINGS => total(earned.values), UNREALIZED => total(at_cost.values + negated(assets)) }
      rows.merge(CONVERSIONS => total(negated(sheet.values + rows.values)))
    end

    def negated(amounts_list) = amounts_list.map { |amounts| amounts.transform_values(&:-@) }

    # {currency => sum} over a list of {currency => number}, without the zeros.
    def total(amounts_list)
      sum = Hash.new(BigDecimal('0'))
      amounts_list.each { |amounts| amounts.each { |c, n| sum[c] += n } }
      sum.reject { |_, n| n.zero? }
    end

    # One entry per transaction with a posting under `prefix` ('' keeps every
    # transaction, every posting unmatched), each with all of its postings,
    # unmatched ones first. `text` is escaped through `bql_text`.
    def journal(prefix, from, to, mxn: true, text: nil)
      bql = journal_query(from, to, mxn: mxn, text: text)
      rows = JSON.parse(run(bql)).fetch('rows').map { |row| journal_row(row) }
      rows.group_by { |row| row[:id] }.values.filter_map { |postings| journal_transaction(prefix, postings) }
    end

    # No account clause: a transaction's other postings are needed too, so the
    # prefix filter runs in Ruby once the rows are grouped.
    def journal_query(from, to, mxn:, text:)
      amount = mxn ? "CONVERT(position, 'MXN', #{to.iso8601})" : 'position'
      bql = "SELECT id, date, flag, payee, narration, filename, lineno, account, #{amount} AS amount " \
            "WHERE date >= #{from.iso8601} AND date <= #{to.iso8601}"
      bql += " AND (payee ~ '#{bql_text(text)}' OR narration ~ '#{bql_text(text)}')" if text && !text.strip.empty?
      bql
    end

    # A journal row, either shape: {id, ...} or a positional array in column order.
    # `lineno` is the posting's line; LedgerEdit walks back from it to the header.
    def journal_row(row)
      columns = %w[id date flag payee narration filename lineno account amount]
      id, date, flag, payee, narration, file, line, account, amount_value =
        row.is_a?(Hash) ? row.values_at(*columns) : row
      units = amount_value['units'] || amount_value
      { id: id, date: Date.iso8601(date), flag: flag, payee: payee, narration: narration, file: file, line: line,
        account: account, amount: { units['currency'] => BigDecimal(units['number']) } }
    end

    # One transaction from its grouped rows, or nil when none of its postings
    # match `prefix`. Matched postings sort after unmatched ones.
    def journal_transaction(prefix, rows)
      postings = rows.map do |r|
        { account: r[:account], amount: r[:amount], matched: journal_matches?(prefix, r[:account]) }
      end
      return nil unless prefix.empty? || postings.any? { |p| p[:matched] }

      matched, unmatched = postings.partition { |p| p[:matched] }
      rows.first.slice(:date, :flag, :payee, :narration, :file, :line).merge(postings: unmatched + matched)
    end

    # The account itself or anything under it. '' matches nothing: Expenses:Foo never covers Expenses:Food.
    def journal_matches?(prefix, account)
      account == prefix || account.start_with?("#{prefix}:")
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

    # BQL for a group's total: market value in MXN at the latest price on or before
    # `at`, stocks via USD, with a commodity that has no price left as it is, so it
    # shows in its own column; or, without `mxn`, valued in its own currency. With
    # `cost`, the book value instead of the market value.
    def valued(at, mxn, cost: false)
      expr = cost ? 'COST(position)' : 'position'
      return "SUM(CONVERT(#{expr}, 'MXN', #{at.iso8601}))" if mxn

      cost ? 'SUM(COST(position))' : "VALUE(SUM(position), #{at.iso8601})"
    end

    def query(bql)
      # 0.22 prints each row as {account, total}; 0.24 as [account, total].
      JSON.parse(run(bql)).fetch('rows').to_h do |row|
        account, total = row.is_a?(Hash) ? row.values_at('account', 'total') : row
        [account, total['positions'].to_h { |p| [p['currency'], BigDecimal(p['number'])] }]
      end
    end

    def run(bql)
      out, err, code = capture('query', '--no-cache', '-q', '-f', 'json', Config.report_file, bql)
      return out if code.zero?

      raise Error, err.strip.empty? ? "rledger salió con #{code}" : err.strip
    end

    # One line per error block that `rledger check` prints: the code, the `x`
    # line and the `,-[file:line:col]` line under it. The file is relative to the ledger.
    CHECK_RE = /^(?<code>[A-Z]\d{4})\n\n\s+x (?<message>.*)\n\s+,-\[(?<file>.*?):(?<line>\d+):\d+\]/

    # `rledger check` over the whole ledger: [] when it is clean, else the errors
    # as "E3001 Transaction does not balance: … (accounts/AMEX/AMEX 2607.beancount:325)".
    # Without `--no-cache` the binary would leave a cache file in the clone.
    def check
      out, err, code = capture('check', '--no-cache', Config.report_file)
      return [] if code.zero?

      root = "#{File.expand_path(Config.ledger_dir)}/"
      errors = (out + err).scan(CHECK_RE).map { |c, m, f, l| "#{c} #{m} (#{f.delete_prefix(root)}:#{l})" }
      raise Error, (out + err).strip if errors.empty?

      errors
    end

    # [stdout, stderr, exit status] of one rledger call. The one seam the tests stub.
    def capture(*)
      out, err, status = Open3.capture3(Config.rledger, *)
      [out, err, status.exitstatus]
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
