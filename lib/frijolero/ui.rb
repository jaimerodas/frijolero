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
        require "cli/ui"
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

      def puts(msg = "")
        ::CLI::UI.puts(msg)
      end

      def fmt(msg)
        ::CLI::UI.fmt(msg)
      end

      def short_path(path)
        home = Dir.home
        path.start_with?(home) ? path.sub(home, "~") : path
      end

      def format_number(n)
        int_part, dec_part = format("%.2f", n).split(".")
        int_with_commas = int_part.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
        "#{int_with_commas}.#{dec_part}"
      end

      def detailer_stats(stats)
        puts "#{stats[:detailed].size} detailed#{transaction_summary(stats[:detailed])}"
        puts "#{stats[:remaining].size} remaining#{transaction_summary(stats[:remaining])}"
      end

      def transaction_summary(transactions)
        return "" if transactions.empty?

        debits = transactions.select { |t| t["amount"].to_f < 0 }
        credits = transactions.select { |t| t["amount"].to_f >= 0 }

        parts = []
        if debits.any?
          total = debits.sum { |t| t["amount"].to_f.abs }
          parts << "#{debits.size} debits (#{format_number(total)})"
        end
        if credits.any?
          total = credits.sum { |t| t["amount"].to_f }
          parts << "#{credits.size} credits (#{format_number(total)})"
        end

        ": #{parts.join(", ")}"
      end
    end
  end
end
