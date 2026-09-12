# frozen_string_literal: true

module Frijolero
  # One directive in one ledger file, found by file and line and edited as raw
  # text, or the whole file when `line` is nil. The journal hands over a
  # posting's line; the block is the header line above it plus the indented
  # lines under it. Any date-headed directive qualifies, `!` transactions
  # included, so this is a line scan of its own and not Beancount::Parser,
  # which skips those on purpose.
  class LedgerEdit
    class NotFound < StandardError; end
    class Stale < StandardError; end

    # The ledger did not validate with the edit in place. The file is back as it
    # was. `errors` are Reports.check's hashes; the message is one line per error.
    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.map { |e| "#{e[:code]} #{e[:message]} (#{e[:file]}:#{e[:line]})" }.join("\n"))
      end
    end

    HEADER_RE = /\A\d{4}-\d{2}-\d{2}\s/
    BODY_RE = /\A[ \t]+\S/
    STATEMENT_RE = %r{\Aaccounts/([^/]+)/\1 (\d{4})\.beancount\z}

    # `file` is relative to the ledger; a path that leaves it, or is not a
    # `.beancount` file, is NotFound. `line` nil or 0 means the whole file.
    # `checker.check` answers with a list of errors.
    def initialize(file:, line:, checker: Reports)
      @file = file.to_s
      @line = line.to_i
      @checker = checker
      root = File.expand_path(Config.ledger_dir)
      @path = File.expand_path(@file, root)
      raise NotFound unless @file.end_with?('.beancount') && @path.start_with?("#{root}/")
    end

    # [key, period] when the file is a statement's, else nil.
    def statement
      match = STATEMENT_RE.match(@file)
      [match[1], match[2]] if match
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
    # For the whole file only "Edición AMEX 2607": git has the diff.
    def commit_message(original:, edited:)
      return "Edición #{target}" if whole_file?

      original = crlf(original)
      header = Beancount::Header.parse(original.lines.first)
      who = header && (header.payee || header.narration)
      "Edición #{target}: #{[original[0, 10], who].compact.join(' ')}\n\nAntes:\n#{original}\nDespués:\n#{crlf(edited)}"
    end

    private

    def whole_file?
      @line.zero?
    end

    def target
      key, period = statement
      key ? "#{key} #{period}" : @file
    end

    def read
      File.readlines(@path)
    rescue SystemCallError
      raise NotFound
    end

    # [first, last] indices of the block around @line, or NotFound.
    def locate(lines)
      return [0, lines.size - 1] if whole_file?
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
      raise Invalid, errors unless errors.empty?
    rescue StandardError
      File.write(@path, before)
      raise
    end

    def crlf(text)
      text.to_s.gsub("\r\n", "\n")
    end
  end
end
