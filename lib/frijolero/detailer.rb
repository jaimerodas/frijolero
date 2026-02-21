# frozen_string_literal: true

require "json"
require "yaml"
require "set"

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

      detailed = @transactions.select { |t| @matched_ids.include?(t.object_id) }
      remaining = @transactions.reject { |t| @matched_ids.include?(t.object_id) }

      {
        total: @transactions.size,
        detailed: detailed,
        remaining: remaining
      }
    end

    private

    def load_json
      @transactions = JSON.load_file(file).dig("transactions")
    end

    def process_transactions
      config = YAML.load_file(@config_path)

      process_patterns(config["start_with"]) do |pattern, transaction|
        transaction["description"].start_with?(pattern)
      end

      process_patterns(config["include"]) do |pattern, transaction|
        transaction["description"].include?(pattern)
      end
    end

    def process_patterns(patterns, &matcher)
      return unless patterns

      patterns.each do |pattern, rules|
        candidates = normalize_rules(rules)

        @transactions
          .select { |t| matcher.call(pattern, t) }
          .each do |t|
            matching = find_matching_rules(candidates, t)
            next unless matching

            apply_rules(matching, t)
            @matched_ids << t.object_id
          end
      end
    end

    def normalize_rules(rules)
      case rules
      when Array then rules
      when Hash then [rules]
      else []
      end
    end

    def find_matching_rules(candidates, transaction)
      candidates.find { |entry| conditions_met?(entry["when"], transaction) }
    end

    def conditions_met?(conditions, transaction)
      return true unless conditions

      conditions.all? do |field, expected|
        case field
        when "amount" then transaction["amount"] == expected
        else false
        end
      end
    end

    def apply_rules(rules, transaction)
      transaction["payee"] = rules["payee"] if rules["payee"]
      transaction["narration"] = rules["narration"] if rules["narration"]
      transaction["expense_account"] = rules["account"] if rules["account"]
    end

    def write_file
      File.write(file, JSON.pretty_generate({"transactions" => @transactions}))
    end
  end
end
