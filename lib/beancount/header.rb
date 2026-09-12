# frozen_string_literal: true

module Frijolero
  module Beancount
    # The first line of a transaction: `DATE FLAG "payee" "narration" #tag ^link`.
    #
    # The payee is optional — one string means narration only. Anything after the
    # strings (tags, links, a trailing comment) is preserved verbatim on render.
    class Header
      LINE_RE = /\A(?<date>\d{4}-\d{2}-\d{2})\s+(?<flag>\S+)\s+(?<rest>.*?)\s*\z/
      TRAILING_RE = /\A(?:[#^]\S+\s*)*(?:;.*)?\z/

      # Returns nil when the line is anything we cannot rewrite unambiguously.
      def self.parse(line)
        return nil unless line

        match = LINE_RE.match(line.chomp)
        return nil unless match

        strings, trailing = split_strings(match[:rest])
        return nil unless (1..2).cover?(strings.size) && trailing.match?(TRAILING_RE)

        new(match[:date], match[:flag], strings, trailing, line[/\r?\n\z/] || '')
      end

      def self.split_strings(rest)
        strings = []
        while strings.size < 2 && (taken = Quoting.take_string(rest))
          strings << taken.first
          rest = taken.last
        end
        [strings, rest.strip]
      end

      attr_reader :payee, :narration, :eol, :flag

      def initialize(date, flag, strings, trailing, eol)
        @date = date
        @flag = flag
        @payee, @narration = strings.size == 2 ? strings : [nil, strings.first]
        @trailing = trailing
        @eol = eol
      end

      # Renders the line with the given overrides; nil means "leave as it was".
      # The flag is never touched — a `!` someone set stays a `!`.
      def render(payee: nil, narration: nil)
        strings = [payee || @payee, narration || @narration].compact
        parts = [@date, @flag, *strings.map { |string| %("#{Quoting.escape(string)}") }, @trailing]

        "#{parts.reject { |part| part.nil? || part.empty? }.join(' ')}#{@eol}"
      end
    end
  end
end
