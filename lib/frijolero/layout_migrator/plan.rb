# frozen_string_literal: true

module Frijolero
  class LayoutMigrator
    # Immutable description of what a migration would do. Built by PlanBuilder,
    # consumed by LayoutMigrator and PlanFormatter. Add a method here instead
    # of teaching callers a new bucket name.
    Plan = Struct.new(:copies, :redundants, :conflicts, :unhandled, :warnings, keyword_init: true) do
      def copies_by_kind
        copies.group_by(&:kind)
      end

      def total_copy_bytes
        copies.sum { |c| File.size(c.src) }
      end
    end
  end
end
