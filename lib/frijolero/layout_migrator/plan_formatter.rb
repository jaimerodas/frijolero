# frozen_string_literal: true

module Frijolero
  class LayoutMigrator
    class PlanFormatter
      KINDS = %i[transactions beancount json pdf].freeze
      BYTES_UNITS = %w[B KB MB GB TB].freeze

      def initialize(io:, old_root:, new_root:, main_file:)
        @io = io
        @old_root = old_root
        @new_root = new_root
        @main_file = main_file
      end

      def print_plan(plan)
        @io.puts "Migration plan: #{@old_root} → #{@new_root}"
        @io.puts
        print_copies_by_kind(plan)
        print_total(plan)
        print_extras(plan)
        print_rewrite_count
      end

      def print_summary(plan, outcome, backup_path)
        @io.puts
        @io.puts "Copied & verified: #{outcome.completed.size} file(s)"
        @io.puts "Backup: #{backup_path}" if backup_path
        print_summary_conflicts(plan.conflicts + outcome.extra_conflicts)
        @io.puts "Unhandled: #{plan.unhandled.size}" unless plan.unhandled.empty?
      end

      private

      def print_summary_conflicts(conflicts)
        print_section('Conflicts', conflicts) { |c| "#{relative(c.src)} — #{c.reason}" }
      end

      def print_copies_by_kind(plan)
        grouped = plan.copies_by_kind
        KINDS.each do |kind|
          next unless grouped[kind]

          @io.puts "  #{kind} (#{grouped[kind].size}):"
          grouped[kind].each { |c| @io.puts "    #{relative(c.src)} → #{relative(c.dst)}" }
        end
      end

      def print_total(plan)
        @io.puts
        @io.puts "  Total: #{plan.copies.size} files, ~#{format_bytes(plan.total_copy_bytes)}"
      end

      def print_extras(plan)
        print_section('Redundant duplicates', plan.redundants) { |r| relative(r.src) }
        print_section('Conflicts', plan.conflicts) { |c| "#{relative(c.src)} — #{c.reason}" }
        print_section('Unhandled', plan.unhandled) { |u| "#{relative(u.path)} — #{u.reason}" }
        print_warnings(plan.warnings)
      end

      def print_warnings(warnings)
        print_section('Unknown accounts (no accounts.yaml entry, using as-is)', warnings) do |w|
          "#{relative(w.src)} — prefix '#{w.prefix}'"
        end
      end

      def print_section(label, entries)
        return if entries.empty?

        @io.puts
        @io.puts "  #{label} (#{entries.size}):"
        entries.each { |e| @io.puts "    #{yield e}" }
      end

      def print_rewrite_count
        return unless @main_file && File.exist?(@main_file)

        count = File.readlines(@main_file).count { |l| l.match?(%r{^include\s+"transactions/}) }
        @io.puts
        @io.puts "  Main ledger rewrites: #{count} include line(s) in #{@main_file}"
      end

      def relative(path)
        return path unless path

        root = path.start_with?(@new_root) ? @new_root : @old_root
        path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
      end

      def format_bytes(bytes)
        idx = 0
        val = bytes.to_f
        while val >= 1024 && idx < BYTES_UNITS.size - 1
          val /= 1024
          idx += 1
        end
        format('%<val>.1f %<unit>s', val: val, unit: BYTES_UNITS[idx])
      end
    end
  end
end
