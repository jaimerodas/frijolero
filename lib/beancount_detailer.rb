# frozen_string_literal: true

module Frijolero
  # Re-runs detailer rules against an already-converted `.beancount` file, so
  # rules can be added and applied without going back to the JSON and redoing
  # the conversion and the merge.
  #
  # Only transactions still posting to the FIXME account are touched, which is
  # what keeps hand edits (made in fava or otherwise) safe. It is also what
  # makes the run idempotent: a transaction detailed on one pass no longer posts
  # to FIXME, so the next pass skips it and the file comes out byte-identical.
  class BeancountDetailer
    FIXME = Converters::Default::DEFAULT_EXPENSE_ACCOUNT

    def initialize(file, config_path)
      @file = file
      @config_path = config_path
    end

    # How many transactions the rules classified, and how many still post to FIXME.
    def run
      blocks = Beancount::Parser.parse(@file)
      result = self.class.apply(blocks, Detailer::Rules.load(@config_path))
      text = blocks.flat_map { |block| block[:lines] }.join
      File.write(@file, text, encoding: 'UTF-8') if result[:detailed].positive?
      result
    end

    # Applies `rules` to the parsed `blocks`, in place. Revisar calls it with its own blocks
    # and rules, before it writes anything.
    def self.apply(blocks, rules)
      candidates = detailable(blocks)
      matches = matches(candidates, rules)
      matches.each { |transaction, matched| detail(transaction, matched) }
      { detailed: matches.size, remaining: candidates.size - matches.size }
    end

    # Parsed transactions with exactly one FIXME posting. None means it is classified
    # already, by hand or by an earlier run; more than one leaves no way to tell which
    # one a rule meant. A `!` transaction is one someone flagged by hand: never touched.
    def self.detailable(blocks)
      blocks.filter_map { |block| Beancount::Transaction.new(block) if block[:type] == :transaction }
            .select { |t| t.parsed? && t.flag != '!' && t.postings_to(FIXME).size == 1 }
    end

    # {transaction => the rules that match it}, for the ones some rule matches.
    def self.matches(candidates, rules)
      candidates.to_h { |t| [t, rules.matches_for(description: t.description, amount: t.amount)] }
                .reject { |_, matched| matched.empty? }
    end

    def self.detail(transaction, matched)
      transaction.apply(**Detailer::Rules.merge(matched).transform_keys(&:to_sym),
                        posting_index: transaction.postings_to(FIXME).first[:index])
    end
    private_class_method :detailable, :matches, :detail
  end
end
