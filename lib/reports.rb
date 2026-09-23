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
    # unmatched ones first.
    # `ids` limits it to those transactions, the journal's page, which the
    # index already filtered by text; [] runs no query.
    def journal(prefix, from, to, mxn: true, ids: nil)
      return [] if ids == []

      bql = journal_query(from, to, mxn: mxn)
      bql += " AND id IN (#{ids.join(', ')})" if ids
      rows = table(bql).map { |row| journal_row(row) }
      rows.group_by { |row| row[:id] }.values.filter_map { |postings| journal_transaction(prefix, postings) }
    end

    # Every transaction of the journal, light: its id, date, payee and only the
    # postings under `prefix`, all matched. The page counts, totals, sorts and
    # charts these, then fetches its own transactions whole through `journal`.
    # With '' there are no postings and no payee.
    def journal_index(prefix, from, to, mxn: true, text: nil)
      table(journal_index_query(prefix, from, to, mxn, text)).group_by(&:first).map do |id, postings|
        _, date, payee = postings.first
        { id: id, date: Date.iso8601(date), payee: payee,
          postings: postings.filter_map { |p| { account: p[3], amount: amount(p[4]), matched: true } if p[3] } }
      end
    end

    # `prefix` is validated by the route before it gets here, as in `opening`.
    def journal_index_query(prefix, from, to, mxn, text)
      where = journal_where(from, to, text)
      return "SELECT id, date WHERE #{where} GROUP BY id, date" if prefix.empty?

      "SELECT id, date, payee, account, #{journal_amount(to, mxn)} AS amount WHERE #{where} " \
        "AND account ~ '^#{prefix}(:|$)'"
    end

    # The rows of a query as arrays in column order, from either shape.
    def table(bql) = JSON.parse(run(bql)).fetch('rows').map { |row| row.is_a?(Hash) ? row.values : row }

    # The balance of `prefix` (the account and its subtree) the day before `from`,
    # {currency => BigDecimal} in the ledger's sign; with `mxn`, at the closing
    # rate of `to`, like the journal's postings, so opening plus postings lands on
    # the balance sheet's figure. `prefix` is validated by the route before it gets here.
    def opening(prefix, from, to, mxn: true)
      sum = mxn ? valued(to, true) : 'SUM(position)'
      rows = query("SELECT account, #{sum} AS total WHERE date < #{from.iso8601} " \
                   "AND account ~ '^#{prefix}(:|$)' GROUP BY account")
      total(rows.values)
    end

    # No account clause: a transaction's other postings are needed too, so the
    # prefix filter runs in Ruby once the rows are grouped.
    def journal_query(from, to, mxn:)
      "SELECT id, date, flag, payee, narration, filename, lineno, account, #{journal_amount(to, mxn)} AS amount " \
        "WHERE #{journal_where(from, to, nil)}"
    end

    def journal_amount(to, mxn) = mxn ? "CONVERT(position, 'MXN', #{to.iso8601})" : 'position'

    def journal_where(from, to, text)
      where = "date >= #{from.iso8601} AND date <= #{to.iso8601}"
      where += " AND (payee ~ '#{bql_text(text)}' OR narration ~ '#{bql_text(text)}')" if text && !text.strip.empty?
      where
    end

    # A journal row in column order (`table` flattens either shape).
    # `lineno` is the posting's line; LedgerEdit walks back from it to the header.
    def journal_row(row)
      id, date, flag, payee, narration, file, line, account, amount_value = row
      { id: id, date: Date.iso8601(date), flag: flag, payee: payee, narration: narration,
        file: ledger_file(file), line: line, account: account, amount: amount(amount_value) }
    end

    # {currency => BigDecimal} from a position ({units: ...}) or a CONVERT amount.
    def amount(value)
      units = value['units'] || value
      { units['currency'] => BigDecimal(units['number']) }
    end

    # One transaction from its grouped rows, or nil when none of its postings
    # match `prefix`. Matched postings sort after unmatched ones.
    def journal_transaction(prefix, rows)
      postings = rows.map do |r|
        { account: r[:account], amount: r[:amount], matched: journal_matches?(prefix, r[:account]) }
      end
      return nil unless prefix.empty? || postings.any? { |p| p[:matched] }

      matched, unmatched = postings.partition { |p| p[:matched] }
      rows.first.slice(:id, :date, :flag, :payee, :narration, :file, :line).merge(postings: unmatched + matched)
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
    # A ledger with no transactions yet answers nil, and the pages say so.
    def first_date
      value = table('SELECT MIN(date) AS first').dig(0, 0)
      Date.iso8601(value) unless value.to_s.empty?
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
      table(bql).to_h do |account, total|
        [account, total['positions'].to_h { |p| [p['currency'], BigDecimal(p['number'])] }]
      end
    end

    def run(bql)
      out, err, code = capture('query', '--no-cache', '-q', '-f', 'json', Config.main_file, bql)
      return out if code.zero?

      raise Error, err.strip.empty? ? "rledger salió con #{code}" : err.strip
    end

    # One line per error block that `rledger check` prints: the code, the `x`
    # line and the `,-[file:line:col]` line under it. The file is relative to the ledger.
    CHECK_RE = /^(?<code>[A-Z]\d{4})\n\n\s+x (?<message>.*)\n\s+,-\[(?<file>.*?):(?<line>\d+):\d+\]/

    # `rledger check` over the whole ledger: [] when it is clean, else one
    # {code:, message:, file:, line:} per error, the file relative to the ledger.
    # Without `--no-cache` the binary would leave a cache file in the clone.
    def check
      out, err, code = capture('check', '--no-cache', Config.main_file)
      return [] if code.zero?

      errors = (out + err).scan(CHECK_RE).map do |c, m, f, l|
        { code: c, message: m, file: ledger_file(f), line: l.to_i }
      end
      raise Error, (out + err).strip if errors.empty?

      errors
    end

    # A file rledger printed, relative to the ledger. rledger resolves symlinks, and
    # bin/dev reaches the ledger through one, so the root is the real path too.
    def ledger_file(file)
      file.delete_prefix("#{File.realpath(Config.ledger_dir)}/")
    end

    # [stdout, stderr, exit status] of one rledger call. The one seam the tests stub.
    def capture(*)
      out, err, status = Open3.capture3(Config.rledger, *)
      [out, err, status.exitstatus]
    rescue Errno::ENOENT
      raise Error, "rustledger no está instalado (#{Config.rledger}): brew install rustledger, o pon RLEDGER"
    end

    # One row per account and per ancestor, in tree order, with the parents
    # carrying the sum of their subtree: {name:, depth:, amounts:, total:}.
    # An account at zero in every currency is left out, as on a printed sheet.
    # `sort` orders the siblings under each parent: `name-asc`, `name-desc`, or `<currency>-asc|desc`,
    # by the subtotal in that currency in the report sign, so desc is the biggest first on every root.
    def tree(flat, sort: 'name-asc')
      sums = subtotals(flat.reject { |_, amounts| amounts.values.all?(&:zero?) })
      branch(sums, nil, order(sums, sort))
    end

    # The sort of a sibling group. An amount tie keeps the names ascending in either direction.
    def order(sums, sort)
      by, _, direction = sort.rpartition('-')
      flip = direction == 'desc' ? -1 : 1
      lambda do |names|
        next names.sort_by { |k| [sums[k][by] * sign(k) * flip, k] } unless by == 'name'

        flip.negative? ? names.sort.reverse : names.sort
      end
    end

    # The rows under `parent`, each followed by its own subtree.
    # ponytail: O(n²) children scan; ~130 accounts.
    def branch(sums, parent, children)
      depth = parent ? parent.count(':') + 1 : 0
      names = sums.keys.select { |k| k.count(':') == depth && (parent.nil? || k.start_with?("#{parent}:")) }
      children.call(names).flat_map do |name|
        rows = branch(sums, name, children)
        [{ name: name, depth: depth, amounts: sums[name], total: !rows.empty? }, *rows]
      end
    end

    # The report sign: a credit account reads positive on the page.
    def sign(account) = account.start_with?('Income', 'Liabilities', 'Equity') ? -1 : 1

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
