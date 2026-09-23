# frozen_string_literal: true

require 'json'

require_relative 'detailer/rules'

module Frijolero
  # Applies an account's rules to an extraction's JSON, in place.
  class Detailer
    def initialize(file, config_path)
      @file = file
      @config_path = config_path
    end

    def run
      transactions = JSON.load_file(@file)['transactions']
      rules = Rules.load(@config_path)
      detailed, remaining = transactions.partition do |transaction|
        matched = rules.matches_for(description: transaction['description'], amount: transaction['amount'])
        transaction.merge!(Rules.merge(matched).transform_keys('account' => 'expense_account'))
        matched.any?
      end
      File.write(@file, JSON.pretty_generate({ 'transactions' => transactions }))
      { detailed: detailed, remaining: remaining }
    end
  end
end
