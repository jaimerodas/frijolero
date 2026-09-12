# frozen_string_literal: true

require 'bigdecimal'

module Frijolero
  module Beancount
    # A structured, editable view of one `:transaction` block from Parser.parse.
    #
    # Edits are surgical: only the header line and the posting the caller points
    # at are rewritten, so metadata, comments and postings added by hand in fava
    # survive verbatim.
    class Transaction
      METADATA_RE = /\A\s+(?<key>[a-z][\w-]*):\s*(?<value>.*?)\s*\z/
      # Account names may hold non-ASCII letters (`Expenses:Café`), so this has
      # to be unicode-aware: an unparsed posting means a nil amount, which would
      # make a `when: {amount:}` rule fall through to the wrong fallback.
      POSTING_RE = /\A\s+(?<account>[[:upper:]][[:word:]:-]*)(?<tail>\s.*?)?\s*\z/
      AMOUNT_RE = /\A\s*(-?[\d,]+(?:\.\d+)?)\s+([A-Z][A-Z0-9._-]*)/
      DEFAULT_INDENT = '  '

      attr_reader :block

      def initialize(block)
        @block = block
        @header = Header.parse(block[:lines].first)
      end

      def parsed?
        !@header.nil?
      end

      def payee
        @header&.payee
      end

      def narration
        @header&.narration
      end

      def flag
        @header&.flag
      end

      def metadata
        @metadata ||= body.each_with_object({}) do |line, acc|
          match = METADATA_RE.match(line.chomp)
          acc[match[:key]] = Quoting.unquote(match[:value]) if match
        end
      end

      # The raw bank description. Present as `source_desc` whenever a rule
      # replaced the narration; otherwise the narration still is the description.
      def description
        metadata['source_desc'] || narration
      end

      def postings
        @postings ||= @block[:lines].each_with_index.filter_map { |line, idx| parse_posting(line, idx) }
      end

      def postings_to(account)
        postings.select { |posting| posting[:account] == account }
      end

      def amount
        postings.filter_map { |posting| posting[:amount] }.first
      end

      # Rewrites this transaction in place. Only non-nil fields are applied, so a
      # rule that sets a payee but no narration leaves the narration alone.
      def apply(payee: nil, narration: nil, account: nil, posting_index: nil)
        original_description = description
        rewrite_posting(posting_index, account) if account && posting_index
        record_source_desc(original_description) if narration && !metadata.key?('source_desc')
        @block[:lines][0] = @header.render(payee: payee, narration: narration)
        reset_cache
      end

      private

      def body
        @block[:lines].drop(1)
      end

      def reset_cache
        @metadata = nil
        @postings = nil
        @header = Header.parse(@block[:lines].first)
      end

      def parse_posting(line, index)
        match = POSTING_RE.match(line.chomp)
        return nil unless match

        { index: index, account: match[:account], **parse_amount(match[:tail]) }
      end

      # { amount:, currency: } of a posting that carries one; nothing when it does not.
      def parse_amount(tail)
        match = tail && AMOUNT_RE.match(tail)
        return {} unless match

        { amount: BigDecimal(match[1].delete(',')), currency: match[2] }
      end

      def rewrite_posting(index, new_account)
        old_account = postings.find { |posting| posting[:index] == index }&.fetch(:account)
        return unless old_account

        @block[:lines][index] = @block[:lines][index].sub(/\A(\s*)#{Regexp.escape(old_account)}/) do
          "#{Regexp.last_match(1)}#{new_account}"
        end
      end

      def record_source_desc(value)
        return unless value

        @block[:lines].insert(1, %(#{body_indent}source_desc: "#{Quoting.escape(value)}"#{@header.eol}))
      end

      def body_indent
        indented = body.find { |line| line.match?(/\A[ \t]+\S/) }
        indented ? indented[/\A[ \t]+/] : DEFAULT_INDENT
      end
    end
  end
end
