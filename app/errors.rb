# frozen_string_literal: true

module Frijolero
  # What `rledger check` says about the ledger: the red lines of the editors, and
  # what the badge, the error page and the journal read. Reopens App.
  class App
    # The message of a failed balance (E2001), as rledger writes it.
    BALANCE_FAILED = /\ABalance failed for (?<account>\S+): expected (?<expected>\S+) (?<currency>\S+), got (?<got>\S+)/

    class << self
      # Reports.check's errors, or nil when rledger could not say. The check runs
      # again only when a `.beancount` file of the ledger changed, came or went:
      # on the real ledger the scan is 146 files in 3 ms, the check 46 ms and a
      # 20 MB child. Two threads may both run it once; the answer is the same.
      def ledger_errors
        stamp = ledger_stamp
        key = [reports, Config.ledger_dir, stamp]
        @ledger_errors = [key, checked_errors] unless stamp && @ledger_errors&.first == key
        @ledger_errors.last
      end

      private

      # nil when a file went away during the scan, which means check again.
      def ledger_stamp
        dir = Config.ledger_dir
        Dir.glob('**/*.beancount', base: dir).map { |file| [file, File.mtime(File.join(dir, file))] }.hash
      rescue SystemCallError
        nil
      end

      def checked_errors
        reports.check
      rescue Reports::Error
        nil
      end
    end

    helpers do
      def ledger_errors = self.class.ledger_errors

      # The errors whose directive starts in `file` between lines `first` and `last`.
      def errors_in(file, first, last)
        (ledger_errors || []).select { |e| e[:file] == file && e[:line].between?(first, last) }
      end

      # The error of each line, or nil: an error covers its directive's first line and
      # the indented lines under it, as editor.js marks them.
      def error_lines(lines, errors)
        starts = errors.to_h { |e| [e[:line], e] }
        error = nil
        lines.each_with_index.map { |line, i| error = starts[i + 1] || (error if line.match?(/\A[ \t]+\S/)) }
      end
    end

    helpers do
      # The account a failed balance names, or nil for any other error.
      def balance_account(error) = error[:code] == 'E2001' ? error[:message][BALANCE_FAILED, :account] : nil

      # A failed balance in the page's words, with the gap in plain sight, since the
      # gap is the amount to look for: "el ledger suma 949,165.49 MXN, 200,000.00 menos
      # que el saldo de 1,149,165.49". nil for any other error, which keeps rledger's words.
      def balance_gap(error)
        m = BALANCE_FAILED.match(error[:message]) if error[:code] == 'E2001'
        return unless m

        expected = BigDecimal(m[:expected])
        got = BigDecimal(m[:got])
        "el ledger suma #{datum(got)} #{m[:currency]}, #{datum((got - expected).abs)} " \
          "#{got < expected ? 'menos' : 'más'} que el saldo de #{datum(expected)}"
      end

      # For a failed balance: the journal of the account it names, over the year of
      # the day before it. A balance counts what came before its date, and a year holds
      # the last good balance too, so the culprit sits between the two. nil when the
      # message names no account or the directive is gone.
      def balance_journal_link(error)
        account = balance_account(error)
        return unless account

        line = LedgerEdit.new(file: error[:file], line: error[:line], checker: self.class.reports).block[:text]
        "/journal?account=#{Rack::Utils.escape(account)}&period=#{(Date.iso8601(line[0, 10]) - 1).year}"
      rescue LedgerEdit::NotFound, Date::Error
        nil
      end
    end

    # The errors of `rledger check`, one section per file, or the clean/failed states.
    get '/errors' do
      erb :errors, locals: { errors: ledger_errors }
    end
  end
end
