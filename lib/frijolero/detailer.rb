# frozen_string_literal: true

require "json"
require "yaml"

module Frijolero
  class Detailer
    METADATA_FIELDS = %w[payee narration expense_account].freeze

    def initialize(file, config_path)
      @file = file
      @config_path = config_path
      @transactions = []
    end

    attr_reader :file
    attr_accessor :transactions

    def run
      load_json
      metadata_presence_before = @transactions.map { |transaction| metadata_present?(transaction) }
      process_transactions
      metadata_presence_after = @transactions.map { |transaction| metadata_present?(transaction) }
      write_file

      {
        metadata_enriched: metadata_presence_after.each_with_index.count do |has_metadata, index|
          has_metadata && !metadata_presence_before[index]
        end,
        metadata_remaining: metadata_presence_after.count(false)
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
          end
      end
    end

    def write_file
      File.write(file, JSON.pretty_generate({"transactions" => @transactions}))
    end

    def metadata_present?(transaction)
      METADATA_FIELDS.any? do |field|
        value = transaction[field]
        !value.nil? && value != ""
      end
    end
  end
end
