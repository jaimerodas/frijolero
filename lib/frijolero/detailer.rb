# frozen_string_literal: true

require 'json'

require_relative 'detailer/rules'

module Frijolero
  class Detailer
    def initialize(file, config_path)
      @file = file
      @config_path = config_path
      @transactions = []
      @matched_ids = Set.new
    end

    attr_reader :file
    attr_accessor :transactions

    def run
      load_json
      process_transactions
      write_file

      detailed, remaining = @transactions.partition { |t| @matched_ids.include?(t.object_id) }

      {
        total: @transactions.size,
        detailed: detailed,
        remaining: remaining
      }
    end

    private

    def load_json
      @transactions = JSON.load_file(file)['transactions']
    end

    def process_transactions
      rules = Rules.load(@config_path)

      @transactions.each do |transaction|
        matching = rules.matches_for(
          description: transaction['description'],
          amount: transaction['amount']
        )
        next if matching.empty?

        matching.each { |rule| apply_rules(rule, transaction) }
        @matched_ids << transaction.object_id
      end
    end

    def apply_rules(rules, transaction)
      transaction['payee'] = rules['payee'] if rules['payee']
      transaction['narration'] = rules['narration'] if rules['narration']
      transaction['expense_account'] = rules['account'] if rules['account']
    end

    def write_file
      File.write(file, JSON.pretty_generate({ 'transactions' => @transactions }))
    end
  end
end
