# frozen_string_literal: true

module Frijolero
  # What `rledger check` says about the ledger: the red lines of the editors, and
  # what the badge, the error page and the journal read. Reopens App.
  class App
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
    end
  end
end
