# frozen_string_literal: true

require_relative "base_detailer"
require "yaml"

class GenericDetailer < BaseDetailer
  def initialize(file, config_path)
    super(file)
    @config_path = config_path
  end

  private

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
end

if $PROGRAM_NAME == __FILE__
  file = ARGV[0]
  config = ARGV[1]
  abort("Usage: ruby generic_detailer.rb FILE.json CONFIG.yaml") unless file && config
  GenericDetailer.new(file, config).run
end
