# frozen_string_literal: true

require 'set'

module Frijolero
  module Beancount
    class MainFileWriter
      MAX_BLANK_RUN = 2

      def initialize(path)
        @path = path
      end

      def rewrite(blocks:, extracted_groups:, prefix:)
        extracted_ids = Set.new(extracted_groups.values.flatten.map(&:object_id))
        new_lines = build_new_lines(blocks, extracted_ids, prefix)
        File.write(@path, collapse_blank_runs(new_lines).join)
      end

      private

      def build_new_lines(blocks, extracted_ids, prefix)
        include_inserted = Set.new
        new_lines = []

        blocks.each do |block|
          if extracted_transaction?(block, extracted_ids)
            yymm = date_to_yymm(block[:date])
            new_lines << include_line(prefix, yymm) if include_inserted.add?(yymm)
          elsif block[:type] != :marker
            new_lines.concat(block[:lines])
          end
        end

        new_lines
      end

      def extracted_transaction?(block, extracted_ids)
        block[:type] == :transaction && extracted_ids.include?(block.object_id)
      end

      def date_to_yymm(date)
        date[2, 2] + date[5, 2]
      end

      def include_line(prefix, yymm)
        "include \"#{prefix}/#{prefix}_#{yymm}.beancount\"\n"
      end

      def collapse_blank_runs(lines)
        cleaned = []
        blank_count = 0

        lines.each do |line|
          if line.strip.empty?
            blank_count += 1
            cleaned << line if blank_count <= MAX_BLANK_RUN
          else
            blank_count = 0
            cleaned << line
          end
        end

        cleaned
      end
    end
  end
end
