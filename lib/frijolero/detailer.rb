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
      {
        total: @transactions.size,
        detailed: @matched_ids.size,
        remaining: @transactions.size - @matched_ids.size
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
        @transactions
          .select { |t| matcher.call(pattern, t) }
          .each do |t|
            t["payee"] = rules["payee"] if rules["payee"]
            t["narration"] = rules["narration"] if rules["narration"]
            t["expense_account"] = rules["account"] if rules["account"]
            @matched_ids << t.object_id
          end
      end
    end

    def write_file
      File.write(file, JSON.pretty_generate({"transactions" => @transactions}))
    end
  end
end
