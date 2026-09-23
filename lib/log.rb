# frozen_string_literal: true

module Frijolero
  # Plain-line output for the pipeline. The web app points `sink` at a job log.
  module Log
    @sink = $stdout

    class << self
      attr_accessor :sink

      def puts(msg = '')
        sink.puts(msg)
      end

      # Relative to the ledger, where every path the pipeline logs lives.
      def short_path(path) = path.delete_prefix("#{Config.ledger_dir}/")

      def detailer_stats(stats)
        puts "#{stats[:detailed].size} detailed#{transaction_summary(stats[:detailed])}"
        puts "#{stats[:remaining].size} remaining#{transaction_summary(stats[:remaining])}"
      end

      def transaction_summary(transactions)
        return '' if transactions.empty?

        debits, credits = transactions.partition { |t| t['amount'].to_f.negative? }

        parts = []
        parts << format_summary_part('debits', debits) { |t| t['amount'].to_f.abs } if debits.any?
        parts << format_summary_part('credits', credits) { |t| t['amount'].to_f } if credits.any?

        ": #{parts.join(', ')}"
      end

      def format_summary_part(label, transactions, &)
        total = transactions.sum(&)
        "#{transactions.size} #{label} (#{Converters::Amounts.group(format('%.2f', total))})"
      end
    end
  end
end
