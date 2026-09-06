# frozen_string_literal: true

module Frijolero
  # Finds and swaps the raw text block of one top-level key in accounts.yaml,
  # so the file's comments survive an edit. Never parses YAML.
  module AccountBlock
    # The lines that configure `key`: from "Key:" at column 0 up to, not
    # including, the next line that starts at column 0 (a key or a comment).
    # nil when the key is absent.
    def self.extract(text, key)
      lines = text.lines
      range = range(lines, key)
      lines[range].join if range
    end

    # `text` with that block replaced by `block`. Every other byte is identical.
    # Raises KeyError when the key is absent.
    def self.replace(text, key, block)
      lines = text.lines
      range = range(lines, key) or raise KeyError, key
      lines[range] = [block.end_with?("\n") ? block : "#{block}\n"]
      lines.join
    end

    def self.range(lines, key)
      start = lines.index { |line| line.match?(/\A#{Regexp.escape(key)}:[ \t]*(#.*)?$/) } or return
      length = lines[(start + 1)..].index { |line| line.match?(/\A\S/) } || (lines.size - start - 1)
      start..(start + length)
    end
    private_class_method :range
  end
end
