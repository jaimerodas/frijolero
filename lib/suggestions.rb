# frozen_string_literal: true

require 'fileutils'
require 'json'

module Frijolero
  # Revisar's guesses. Each unclassified row of a statement goes to the model with the five past
  # transactions of the ledger closest to it (shared words, each weighed by how rare it is) and
  # the account that the person chose for each, eight rows per call. The model answers three
  # accounts per row, best first, from the open accounts that a statement row can take.
  #
  # Measured on 203 rows of the 2026 statements that the rules missed, each statement with only
  # what came before it: one row per call, 66 % first guess right and 80 % in the three; eight
  # rows, 64 % and 78 %; the whole statement in one call, 63 % and 74 %.
  #
  # A row that a rule matches but gives no account (AMAZON) gets no guess: the person checks it
  # elsewhere. The guesses live outside the ledger, in ledgers/<id>/suggestions/, keyed by date and
  # description, so a save that moves the lines keeps the guesses of the rows left.
  class Suggestions
    EXAMPLES = 5
    ROWS_PER_CALL = 8
    FIXME = BeancountDetailer::FIXME
    KINDS = %w[Expenses: Income: Equity:].freeze

    def self.path(account, period) = File.join(Ledger.current.dir, 'suggestions', "#{account} #{period}.json")

    # { key => [accounts, best first] }; empty before a guess.
    def self.read(account, period)
      path = path(account, period)
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end

    # A row of StatementRows, which both the guess and Revisar read.
    def self.key(row) = "#{row[:date]} #{row[:description]}"

    # The words that tell one merchant from another: no reference, no dollars, no word with a
    # digit, and the RFC as one word.
    def self.words(description)
      text = description.to_s.upcase.sub(%r{\s/REF.*}, '').sub(/D[ÓO]LAR U\.S\.A\..*/, '').sub(/\(USD.*/, '')
      rfc = text[/RFC ?([A-ZÑ&]{3,4}\d{6}[A-Z0-9]{3})/, 1]
      words = text.sub(/RFC ?\S+/, '').split(/[^[:alnum:]]+/).reject { |w| w.size < 2 || w.match?(/\d/) }
      (rfc ? words << "RFC:#{rfc}" : words).uniq
    end

    def initialize(client)
      @client = client
    end

    # Guesses the rows to guess and writes them: the number of rows guessed.
    def write(account, period)
      rows = open_rows(account, period)
      options = LedgerAccounts.active.select { |name| name.start_with?(*KINDS) } - [FIXME]
      return 0 if rows.empty? || options.empty?

      past = past(options)
      guesses = rows.each_slice(ROWS_PER_CALL).map { |chunk| guess(chunk, past, options) }
      save(self.class.path(account, period), guesses.reduce({}, :merge))
    end

    private

    # { key => three accounts } for `rows`, from one call. Strict JSON holds the enum but not
    # the count, so a number outside the list goes and each row keeps three accounts once each.
    def guess(rows, past, options)
      answer = ask(prompt(rows, past), options)
      rows.each.with_index(1).filter_map do |row, number|
        [self.class.key(row), answer[number].uniq.first(3)] if answer[number]
      end.to_h
    end

    # { number => accounts }, as the model answered.
    def ask(text, options) = @client.ask(text, spec(options))['rows'].to_h { |entry| [entry['row'], entry['accounts']] }

    def spec(options)
      PromptSpec.load('suggest', Config.prompts_dir).tap do |spec|
        spec.dig('format', 'schema', 'properties', 'rows', 'items', 'properties', 'accounts', 'items')['enum'] = options
      end
    end

    def save(path, guesses)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(guesses))
      guesses.size
    end

    # What Revisar shows (one FIXME posting), minus the rows that a rule opts out.
    def open_rows(account, period)
      rules = rules(account)
      StatementRows.read(Config.statement_path(account, period, 'beancount'), Config.accounts[account])
                   .select { |row| row[:accounts].count(FIXME) == 1 && !opted_out?(row, rules) }
    end

    def rules(account)
      path = Config.rules_path(account)
      File.exist?(path) ? Detailer::Rules.load(path) : Detailer::Rules.new({})
    end

    def opted_out?(row, rules)
      matched = rules.matches_for(description: row[:description], amount: row[:amount])
      matched.any? && !Detailer::Rules.merge(matched)['account']
    end

    # Every classified row of the ledger's statements, this one included, whose account the
    # model can answer: a transfer to a bank is no example.
    def past(options)
      statement_rows.filter_map do |row|
        next unless row[:accounts].size == 1 && options.include?(row[:accounts].first)

        row.merge(words: self.class.words(row[:description]))
      end
    end

    def statement_rows
      accounts = Config.accounts
      Dir.glob(File.join(Config.ledger_dir, 'accounts', '*', '*.beancount')).flat_map do |path|
        StatementRows.read(path, accounts[File.basename(File.dirname(path))] || {})
      end
    end

    def prompt(rows, past)
      weight = weights(past)
      rows.each_with_index.map do |row, i|
        examples = closest(row, past, weight).map { |example| "\n   - #{line(example)} → #{example[:accounts].first}" }
        "#{i + 1}. #{row[:date]} #{line(row)}#{examples.join}"
      end.join("\n\n")
    end

    def line(row) = %("#{row[:description]}" #{row[:amount]&.to_s('F')} #{row[:currency]})

    # A word in every past row weighs 0; a word in one weighs the most.
    def weights(past)
      counts = Hash.new(0)
      past.each { |row| row[:words].each { |word| counts[word] += 1 } }
      Hash.new { |weight, word| weight[word] = Math.log((past.size + 1.0) / (counts[word] + 1)) }
    end

    def closest(row, past, weight)
      words = self.class.words(row[:description])
      scored = past.map { |example| [similarity(words, example[:words], weight), example] }
      scored.select { |score, _| score.positive? }.max_by(EXAMPLES, &:first).map(&:last)
    end

    # The cosine of two lists of weighed words.
    def similarity(one, other, weight)
      shared = (one & other).sum { |word| weight[word]**2 }
      shared.zero? ? 0 : shared / (norm(one, weight) * norm(other, weight))
    end

    def norm(words, weight) = Math.sqrt(words.sum { |word| weight[word]**2 })
  end
end
