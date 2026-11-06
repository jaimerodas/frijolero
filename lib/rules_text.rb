# frozen_string_literal: true

require 'yaml'

module Frijolero
  # A new `start_with` entry, written into the text of a rules file: text, not YAML.dump, so the
  # file keeps its comments, quotes and order. "Hacer regla" and Revisar write their rules here.
  module RulesText
    module_function

    # [content with an entry for `description` closing `start_with`, the offset after its
    # `account: `]. Without `fields` (Hacer regla) the fields are empty, not '', because the rules
    # skip an empty field: a payee left blank keeps the transaction's own. The caret goes where
    # the autocomplete helps. Revisar passes the fields that the person filled in.
    def with_rule(content, description, fields = nil)
      content += "\n" unless content.empty? || content.end_with?("\n")
      lines = content.sub(/^start_with:\s*\{\s*\}[ \t]*$/, 'start_with:').lines
      at = slot(lines)
      lines.insert(at, entry(description, fields))
      [lines.join, lines[..at].join.size - 1]
    end

    def entry(description, fields)
      return "  #{scalar(description)}:\n    payee:\n    narration:\n    account: \n" unless fields

      "  #{scalar(description)}:\n#{fields.map { |name, value| "    #{name}: #{scalar(value)}\n" }.join}"
    end

    # A string as YAML writes a value, quoted only when it must be; as a key Psych would switch
    # to the `? key` form past 128 characters, and a BBVA description often is longer.
    def scalar(text) = YAML.dump(text, line_width: -1).delete_prefix('--- ').chomp

    # Where the entry goes: after the last indented line of `start_with:`, before the next
    # top-level key; a file without the section gets one.
    def slot(lines)
      head = lines.index { |line| line.start_with?('start_with:') }
      return lines.push("start_with:\n").size unless head

      body = lines[(head + 1)..].take_while { |line| !line.match?(/\A[^\s#]/) }
      last = body.rindex { |line| line.match?(/\A\s+\S/) }
      last ? head + last + 2 : head + 1
    end
  end
end
