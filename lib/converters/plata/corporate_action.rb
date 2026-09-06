# frozen_string_literal: true

module Frijolero
  module Converters
    class Plata < Base
      # A `Stock Split` or `Stock SpinOff` group: the rows Alpaca prints for one
      # corporate action on one date.
      #
      # These conserve cost basis -- the shares removed and the shares added are the
      # same money -- but the printed per-share prices do not say so. NFLX went from
      # 5 at 480.46 (2402.30) to 50 at 48.05, which multiplies back to 2402.50.
      # Trusting the new price would invent twenty cents of basis and leave the
      # transaction unbalanced, so the removed total is authoritative and the
      # additions are allocated against it: each takes its printed value except the
      # largest, which absorbs the remainder.
      #
      # The sign of Quantity separates the two sides, not the description. A spinoff's
      # target row ("Target Symbol: MBGL, Initiating Symbol: SPGI...") carries neither
      # the word ADD nor REMOVE.
      class CorporateAction
        include Amounts

        Leg = Struct.new(:symbol, :quantity, :total, keyword_init: true)

        def initialize(entries)
          @entries = entries
        end

        def removed_total
          @removed_total ||= removals.sum { |entry| (-entry.quantity) * entry.price }
        end

        def removed_legs
          removals.map do |entry|
            Leg.new(symbol: entry.symbol, quantity: entry.quantity,
                    total: (-entry.quantity) * entry.price)
          end
        end

        def added_legs
          @added_legs ||= allocate(additions)
        end

        # A removal with nothing added cannot balance on its own. The converter flags
        # such a group rather than emitting a file beancount will reject.
        def balanced?
          additions.any?
        end

        def narration
          label = @entries.first.entry_type
          source = symbols(removals)
          appeared = symbols(additions) - source
          suffix = appeared.empty? ? '' : " -> #{appeared.join('/')}"

          "#{label} #{source.join('/')}#{suffix}".squeeze(' ').strip
        end

        def descriptions
          @entries.filter_map(&:description).uniq
        end

        private

        def removals
          @removals ||= @entries.select { |entry| entry.quantity.negative? }
        end

        def additions
          @additions ||= @entries.select { |entry| entry.quantity.positive? }
        end

        def symbols(entries)
          entries.filter_map(&:symbol).uniq
        end

        # Printed values for every leg but the largest, which takes whatever is left
        # of the removed basis. That keeps the residue where it is proportionally
        # smallest, and guarantees the group sums to zero.
        def allocate(entries)
          legs = entries.map do |entry|
            Leg.new(symbol: entry.symbol, quantity: entry.quantity,
                    total: entry.quantity * entry.price)
          end
          return legs if legs.empty?

          largest = legs.max_by(&:total)
          largest.total = removed_total - (legs.sum(&:total) - largest.total)
          legs
        end
      end
    end
  end
end
