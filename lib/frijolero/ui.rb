# frozen_string_literal: true

module Frijolero
  # Plain-line output for the pipeline. The web app points `sink` at a job log.
  module UI
    GLYPHS = { '{{x}}' => '✗', '{{v}}' => '✓', '{{i}}' => 'ℹ', '{{!}}' => '!', '{{?}}' => '?', '{{*}}' => '*' }.freeze

    # Tiny stand-in for the old gem's spinner object: just tracks its title.
    Spinner = Struct.new(:title) do
      def update_title(new_title)
        self.title = new_title
      end
    end

    @auto_accept = false
    @sink = $stdout

    class << self
      attr_accessor :auto_accept, :sink

      def auto_accept?
        @auto_accept
      end

      def puts(msg = '')
        sink.puts(fmt(msg))
      end

      # Replaces the old glyph markup and strips any other {{color:...}} markers.
      def fmt(msg)
        GLYPHS.reduce(msg.to_s) { |s, (k, v)| s.gsub(k, v) }.gsub(/\{\{\w+:(.*?)\}\}/, '\1')
      end

      # One line with the title, then the block. No nesting, no borders.
      def frame(title, **)
        puts "== #{title}"
        yield
      end

      # Yields an object with `update_title`; prints the final title when the block ends.
      def spinner(title)
        status = Spinner.new(title)
        yield status
        puts status.title
      end

      # There is no terminal to ask; the answer is whatever auto_accept says.
      def confirm(_question, **)
        auto_accept?
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

      def format_summary_part(label, transactions, &block)
        total = transactions.sum(&block)
        "#{transactions.size} #{label} (#{format_number(total)})"
      end
    end
  end
end
