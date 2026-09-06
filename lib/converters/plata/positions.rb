# frozen_string_literal: true

module Frijolero
  module Converters
    class Plata < Base
      # Which commodity accounts the statement says came into existence this period,
      # and which were emptied.
      #
      # The statement never states an opening position, but it reports the closing
      # share count and every movement that produced it, so the opening count is
      # recoverable as `closing - moved`. From there:
      #
      #   opening 0, closing > 0   a position that appeared      -> open
      #   opening > 0, closing 0   a position that was emptied   -> close
      #   opening 0, closing 0     bought and sold this month    -> open and close
      #   otherwise                already held, still held      -> leave alone
      #
      # An exited position drops out of the Holdings table rather than appearing with
      # a zero, so absence there is what stands in for a closing count of zero. The
      # `moved` guard is what keeps that from firing on a symbol the statement only
      # mentions in passing — a dividend for a position sold in an earlier month
      # carries no quantity and must not read as an exit.
      class Positions
        include Amounts

        def initialize(holdings, entries)
          @holdings = holdings || []
          @entries = entries || []
        end

        def opened
          symbols.select { |symbol| moved?(symbol) && opening(symbol).zero? }
        end

        def closed
          symbols.select { |symbol| moved?(symbol) && closing(symbol).zero? }
        end

        private

        def symbols
          @symbols ||= (closings.keys + movements.keys).uniq.sort
        end

        def opening(symbol)
          closing(symbol) - movements.fetch(symbol, BigDecimal(0))
        end

        def closing(symbol)
          closings.fetch(symbol, BigDecimal(0))
        end

        def moved?(symbol)
          movements.key?(symbol)
        end

        def closings
          @closings ||= @holdings.each_with_object({}) do |holding, out|
            symbol = holding['symbol']
            next if symbol.nil?

            out[symbol] = to_d(holding['quantity'])
          end
        end

        # Only rows that carry both a symbol and a share count move a position. That
        # covers trades, corporate actions and securities transfers without naming
        # them, and excludes every cash-only row by construction.
        def movements
          @movements ||= @entries.each_with_object({}) do |entry, totals|
            next if entry.symbol.nil? || entry.quantity.zero?

            totals[entry.symbol] = totals.fetch(entry.symbol, BigDecimal(0)) + entry.quantity
          end
        end
      end
    end
  end
end
