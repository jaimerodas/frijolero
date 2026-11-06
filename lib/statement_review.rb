# frozen_string_literal: true

require 'yaml'

module Frijolero
  # Revisar's save, on the parsed blocks of one statement: the account, payee and narration that the
  # person chose for each unclassified row, the rules to remember, and then the account's rules, old
  # and new, on the rows left. It writes nothing: the route checks the ledger and commits.
  class StatementReview
    FIXME = BeancountDetailer::FIXME
    FIELDS = %w[account payee narration pattern].freeze
    RULE_FIELDS = %w[payee narration account].freeze
    # One row of the form: its line, its transaction, and its fields, each on one line as a
    # Beancount string must be. The pattern counts only with its Regla box.
    Row = Data.define(:line, :transaction, :choice) do
      def pattern = choice['pattern']
    end
    # Where the pattern of a new rule ends: at the RFC, the /REF of the charge, or the amount in
    # dollars, because the next charge of the same merchant has another reference and amount.
    PATTERN_END = %r{\s*(?:RFC ?[A-ZÑ&]{3,4}\d{6}|/REF|\(?D[óo]lar U\.S\.A\.|;\s).*\z}

    # The rows that cannot be saved, { line => message }. Then nothing is.
    class Invalid < StandardError
      attr_reader :rows

      def initialize(rows)
        @rows = rows
        super('Revisa las filas marcadas: no se guardó nada.')
      end
    end

    # The pattern that the form offers for a new rule.
    def self.pattern(description)
      text = collapse(description)
      pattern = text.sub(PATTERN_END, '')
      pattern.empty? ? text : pattern
    end

    def self.collapse(text) = text.to_s.gsub(/\s+/, ' ').strip

    # { line => transaction } of the rows with one FIXME posting, `!` ones included: here a person chooses.
    def self.unclassified(blocks)
      blocks.filter_map { |block| Beancount::Transaction.new(block) if block[:type] == :transaction }
            .select { |tx| tx.parsed? && tx.postings_to(FIXME).size == 1 }
            .to_h { |tx| [tx.block[:line], tx] }
    end

    # The rules text, with the new rules once `apply` ran; and the new rules, { pattern => fields }.
    attr_reader :rules, :added

    def initialize(path, rules:, accounts:)
      @blocks = Beancount::Parser.parse(path)
      @open = self.class.unclassified(@blocks)
      @rules = rules
      @known = YAML.safe_load(rules)&.dig('start_with')
      @known = {} unless @known.is_a?(Hash)
      @accounts = accounts
      @added = {}
    end

    # `values` is the form: { line => { 'account', 'payee', 'narration', 'rule', 'pattern' } }.
    def apply(values)
      chosen = choose(values)
      chosen.each { |tx, changes| tx.apply(**changes, posting_index: tx.postings_to(FIXME).first[:index]) }
      @added.each { |pattern, fields| @rules = RulesText.with_rule(@rules, pattern, fields).first }
      detail_the_rest(chosen.keys)
      self
    end

    def text = @blocks.flat_map { |block| block[:lines] }.join
    def remaining = self.class.unclassified(@blocks).size
    def classified = @open.size - remaining

    def counts = { classified: classified, rules: @added.size, remaining: remaining }
    def changed?(original) = text != original || !@added.empty?

    private

    def row(line, fields)
      transaction = @open[line.to_i]
      return unless transaction && fields.is_a?(Hash)

      choice = FIELDS.to_h { |name| [name, self.class.collapse(fields[name])] }
      choice['pattern'] = '' unless fields['rule']
      Row.new(line.to_s, transaction, choice)
    end

    # { transaction => what it changes }, and the rules to add in @added; Invalid when a row cannot be saved.
    def choose(values)
      rows = values.filter_map { |line, fields| row(line, fields) }
      check(rows)
      rows.each { |row| remember(row) }
      rows.to_h { |row| [row.transaction, changes(row)] }.reject { |_, changes| changes.empty? }
    end

    def check(rows)
      errors = rows.to_h { |row| [row.line, problem(row)] }.compact
      raise Invalid, errors unless errors.empty?
    end

    # The account, and the payee and narration where they differ from what the row shows: the
    # narration shows only after a rule or a person replaced the description. An empty field keeps.
    def changes(row)
      transaction = row.transaction
      shown = { 'payee' => transaction.payee.to_s,
                'narration' => transaction.metadata.key?('source_desc') ? transaction.narration.to_s : '' }
      row.choice.slice('account', 'payee', 'narration').reject { |name, value| value.empty? || value == shown[name] }
         .transform_keys(&:to_sym)
    end

    # The first row with a pattern gives its rule; another row with the same pattern only gets classified.
    def remember(row)
      return if row.pattern.empty?

      @added[row.pattern] ||= row.choice.slice(*RULE_FIELDS).reject { |_, value| value.empty? }
    end

    def problem(row)
      account = row.choice['account']
      return "Cuenta desconocida: #{account}" unless account.empty? || @accounts.include?(account)

      pattern_problem(row) unless row.pattern.empty?
    end

    def pattern_problem(row)
      unless self.class.collapse(row.transaction.description).start_with?(row.pattern)
        return 'El patrón no es el principio de la descripción'
      end
      return "Ya hay una regla «#{row.pattern}»" if @known.key?(row.pattern)

      'La regla necesita una cuenta, un payee o una narración' if row.choice.values_at(*RULE_FIELDS).all?(&:empty?)
    end

    # The account's rules, with the new ones, on the rows left. Never on a row that the person
    # filled in: the AMAZON rule, which sets no account, would blank the narration they typed.
    def detail_the_rest(chosen)
      touched = chosen.map { |transaction| transaction.block[:line] }
      rest = @blocks.reject { |block| touched.include?(block[:line]) }
      BeancountDetailer.apply(rest, Detailer::Rules.new(YAML.safe_load(@rules)))
    end
  end
end
