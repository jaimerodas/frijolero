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
    def initialize(file, config_path, expense_account: Converters::Default::DEFAULT_EXPENSE_ACCOUNT)
      @file = file
      @config_path = config_path
      @expense_account = expense_account
    end

    attr_reader :file, :expense_account

    def run(dry_run: false)
      blocks = Beancount::Parser.parse(file)
      rules = Detailer::Rules.load(@config_path)
      stats = { total: 0, detailed: [], remaining: [], skipped: [] }

      transactions(blocks).each { |transaction| classify(transaction, rules, stats) }
      write(blocks) unless dry_run || stats[:detailed].empty?

      stats
    end

    private

    # A `!` transaction is one someone flagged by hand: the rules never touch it.
    def transactions(blocks)
      blocks.filter_map { |block| Beancount::Transaction.new(block) if block[:type] == :transaction }
            .reject { |transaction| transaction.flag == '!' }
    end

    def classify(transaction, rules, stats)
      stats[:total] += 1
      targets = transaction.postings_to(@expense_account)
      return if targets.empty? # already categorized by hand — never clobber it

      bucket(transaction, targets, rules, stats)
    end

    def bucket(transaction, targets, rules, stats)
      return stats[:skipped] << summarize(transaction) unless detailable?(transaction, targets)

      matched = rules.matches_for(description: transaction.description, amount: transaction.amount)
      return stats[:remaining] << summarize(transaction) if matched.empty?

      detail(transaction, matched, targets.first[:index], stats)
    end

    # More than one FIXME posting leaves no way to tell which one the rule meant.
    def detailable?(transaction, targets)
      transaction.parsed? && targets.size == 1
    end

    def detail(transaction, matched, posting_index, stats)
      entry = summarize(transaction)
      fields = merge(matched)
      fields[:posting_index] = posting_index
      transaction.apply(**fields)
      stats[:detailed] << entry
    end

    # Same truthy-guard merge as Detailer#apply_rules: a later rule overwrites
    # the fields it sets and leaves the others alone.
    def merge(matched)
      matched.each_with_object({}) do |rule, fields|
        fields[:payee] = rule['payee'] if rule['payee']
        fields[:narration] = rule['narration'] if rule['narration']
        fields[:account] = rule['account'] if rule['account']
      end
    end

    # String keys so Log.detailer_stats and Log.transaction_summary work unchanged.
    def summarize(transaction)
      { 'description' => transaction.description, 'amount' => transaction.amount }
    end

    def write(blocks)
      File.write(file, blocks.flat_map { |block| block[:lines] }.join, encoding: 'UTF-8')
    end
  end
end
