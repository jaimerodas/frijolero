# frozen_string_literal: true

require "json"
require "yaml"

class Detailer
  def initialize(file, config_path)
    @file = file
    @config_path = config_path
    @transactions = []
  end

  attr_reader :file
  attr_accessor :transactions

  def run
    load_json
    process_transactions
    write_file
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
end

if $PROGRAM_NAME == __FILE__
  file = ARGV[0]
  config = ARGV[1]
  abort("Usage: ruby detailer.rb FILE.json CONFIG.yaml") unless file && config
  Detailer.new(file, config).run
end
