# frozen_string_literal: true

module Frijolero
  # One directive in one ledger file, found by file and line and edited as raw
  # text. The journal hands over a posting's line; the block is the header line
  # above it plus the indented lines under it. Any date-headed directive
  # qualifies, `!` transactions included, so this is a line scan of its own and
  # not Beancount::Parser, which skips those on purpose.
  class LedgerEdit
    class NotFound < StandardError; end
    class Stale < StandardError; end
    # The ledger did not validate with the edit in place. The file is back as it was.
    class Invalid < StandardError; end

    HEADER_RE = /\A\d{4}-\d{2}-\d{2}\s/
    BODY_RE = /\A[ \t]+\S/
    STATEMENT_RE = %r{\Aaccounts/([^/]+)/\1 (\d{4})\.beancount\z}

    # `file` is relative to the ledger; a path that leaves it, or is not a
    # `.beancount` file, is NotFound. `checker.check` answers with a list of errors.
    def initialize(file:, line:, checker: Reports)
      @file = file.to_s
      @line = line.to_i
      @checker = checker
      root = File.expand_path(Config.ledger_dir)
      @path = File.expand_path(@file, root)
      raise NotFound unless @file.end_with?('.beancount') && @path.start_with?("#{root}/")
    end

    # { first:, last:, text: }, 1-based lines, of the directive at or above `line`.
    def block
      lines = read
      first, last = locate(lines)
      { first: first + 1, last: last + 1, text: lines[first..last].join }
    end

    # Replaces the block with `edited` and returns the text written, or raises
    # Stale when the block no longer reads as `original`, and Invalid when the
    # ledger does not check clean afterwards, with the file put back either way.
    def save(original:, edited:)
      lines = read
      first, last = locate(lines)
      raise Stale unless lines[first..last].join == crlf(original)

      text = crlf(edited).sub(/\s*\z/, "\n")
      replace(lines.join, (lines[0...first] + [text] + lines[(last + 1)..]).join)
      text
    end

    # "Edición AMEX 2607: 2026-08-01 PASE", then the block before and after.
    def commit_message(original:, edited:)
      original = crlf(original)
      header = Beancount::Header.parse(original.lines.first)
      match = STATEMENT_RE.match(@file)
      target = match ? "#{match[1]} #{match[2]}" : @file
      who = header && (header.payee || header.narration)
      "Edición #{target}: #{[original[0, 10], who].compact.join(' ')}\n\nAntes:\n#{original}\nDespués:\n#{crlf(edited)}"
    end

    private

    def read
      File.readlines(@path)
    rescue SystemCallError
      raise NotFound
    end

    # [first, last] indices of the block around @line, or NotFound.
    def locate(lines)
      raise NotFound unless @line.between?(1, lines.size)

      first = (@line - 1).downto(0).find { |i| lines[i].match?(HEADER_RE) }
      raise NotFound unless first

      last = first
      last += 1 while lines[last + 1]&.match?(BODY_RE)
      [first, last]
    end

    # Writes `after`, and puts `before` back unless the whole ledger checks clean.
    # ponytail: no lock against the job worker; the rules editor has none either.
    def replace(before, after)
      File.write(@path, after)
      errors = @checker.check
      raise Invalid, errors.join("\n") unless errors.empty?
    rescue StandardError
      File.write(@path, before)
      raise
    end

    def crlf(text)
      text.to_s.gsub("\r\n", "\n")
    end
  end
end
