# frozen_string_literal: true

module Frijolero
  module UI
    @auto_accept = false

    class << self
      attr_accessor :auto_accept

      def auto_accept?
        @auto_accept
      end

      def setup
        require 'cli/ui'
        ::CLI::UI::StdoutRouter.enable
      end

      def frame(title, color: :blue, &block)
        ::CLI::UI::Frame.open(title, color: color, &block)
      end

      def spinner(title, &block)
        ::CLI::UI::Spinner.spin(title, &block)
      end

      def confirm(question, default: true)
        return true if auto_accept?

        ::CLI::UI.confirm(question, default: default)
      end

      def puts(msg = '')
        ::CLI::UI.puts(msg)
      end

      def fmt(msg)
        ::CLI::UI.fmt(msg)
      end

      def ask_with_autocomplete(prompt, completions)
        require 'reline'

        old_proc = Reline.completion_proc
        old_append = Reline.completion_append_character

        Reline.completion_append_character = ''
        Reline.completion_proc = proc do |input|
          pattern = input.downcase
          completions.select { |c| c.downcase.include?(pattern) }
        end

        Reline.readline("#{fmt(prompt)} ", false)&.strip
      ensure
        Reline.completion_proc = old_proc
        Reline.completion_append_character = old_append
      end

      def ask_select(prompt, options)
        ::CLI::UI::Prompt.ask(prompt, options: options)
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
