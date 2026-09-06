# frozen_string_literal: true

module Frijolero
  module Beancount
    # Beancount string literals: `"..."` with backslash escapes.
    #
    # Converters::Default does not escape what it writes, so a description
    # containing a quote is already malformed on disk; `Header.parse` rejects
    # those rather than guessing. Everything written back from here is escaped.
    module Quoting
      STRING_RE = /\A"((?:[^"\\]|\\.)*)"\s*/

      # The escapes Beancount itself interprets. Anything else loses just its
      # backslash (`"A\BB"` reads as `ABB`), so unescape mirrors that rather
      # than inventing its own rule — otherwise a rewritten narration would not
      # mean what the original did.
      ESCAPES = { "\n" => '\n', "\t" => '\t', "\r" => '\r', '"' => '\"', '\\' => '\\\\' }.freeze
      UNESCAPES = { 'n' => "\n", 't' => "\t", 'r' => "\r" }.freeze

      module_function

      def escape(string)
        string.gsub(/[\\"\n\t\r]/) { |char| ESCAPES.fetch(char) }
      end

      def unescape(string)
        string.gsub(/\\(.)/m) { UNESCAPES.fetch(Regexp.last_match(1), Regexp.last_match(1)) }
      end

      # Strips the surrounding quotes from a value, leaving bare values as-is.
      def unquote(value)
        match = STRING_RE.match(value)
        match ? unescape(match[1]) : value
      end

      # Peels one leading string literal off `text`, or nil.
      def take_string(text)
        match = STRING_RE.match(text)
        return nil unless match

        [unescape(match[1]), match.post_match]
      end
    end
  end
end
