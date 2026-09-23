# frozen_string_literal: true

module Frijolero
  module Beancount
    module Parser
      TRANSACTION_RE = /^\d{4}-\d{2}-\d{2}\s+[*!]/
      INDENTED_RE = /^\s+\S/

      def self.parse(path)
        lines = File.readlines(path, encoding: 'UTF-8')
        idx = 0
        blocks = []

        while idx < lines.length
          block, idx = parse_next_block(lines, idx)
          blocks << block
        end

        blocks
      end

      def self.parse_next_block(lines, idx)
        line = lines[idx]
        return parse_transaction(lines, idx) if line.match?(TRANSACTION_RE)

        [{ type: :other, lines: [line] }, idx + 1]
      end

      def self.parse_transaction(lines, start_idx)
        date = lines[start_idx][0, 10]
        tx_lines = [lines[start_idx]]
        idx = consume_continuations(lines, start_idx + 1, tx_lines)
        [{ type: :transaction, date: date, lines: tx_lines }, idx]
      end

      def self.consume_continuations(lines, idx, tx_lines)
        while idx < lines.length
          line = lines[idx]
          break unless continuation?(line)

          tx_lines << line
          idx += 1
          break if line.strip.empty?
        end
        idx
      end

      def self.continuation?(line)
        line.match?(INDENTED_RE) || line.strip.empty?
      end
    end
  end
end
