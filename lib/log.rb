# frozen_string_literal: true

module Frijolero
  # Plain-line output for the pipeline. The web app points `sink` at a job log.
  module Log
    GLYPHS = { '{{x}}' => '✗', '{{v}}' => '✓', '{{i}}' => 'ℹ', '{{!}}' => '!', '{{?}}' => '?', '{{*}}' => '*' }.freeze

    @sink = $stdout

    class << self
      attr_accessor :sink

      def puts(msg = '')
        sink.puts(fmt(msg))
      end

      # Replaces the old glyph markup and strips any other {{color:...}} markers.
      def fmt(msg)
        GLYPHS.reduce(msg.to_s) { |s, (k, v)| s.gsub(k, v) }.gsub(/\{\{\w+:(.*?)\}\}/, '\1')
      end

      def short_path(path)
        home = Dir.home
        path.start_with?(home) ? path.sub(home, '~') : path
      end

      def format_number(number)
        int_part, dec_part = format('%.2f', number).split('.')
        int_with_commas = int_part.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
        "#{int_with_commas}.#{dec_part}"
      end

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
        "#{transactions.size} #{label} (#{format_number(total)})"
      end
    end
  end
end
