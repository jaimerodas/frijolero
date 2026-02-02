require_relative "base_detailer"
require "yaml"

class AmexDetailer < BaseDetailer
  private

  def process_transactions
    config = YAML.load_file('amex.yaml')
    start_withs = config["start_with"]
    start_withs.keys.each do |p|
      @transactions.select { |t| t["description"].start_with? p }
        .each do |t|
          t["payee"] = start_withs[p]["payee"] if start_withs[p]["payee"]
          t["narration"] = start_withs[p]["narration"] if start_withs[p]["narration"]
          t["expense_account"] = start_withs[p]["account"] if start_withs[p]["account"]
        end
    end

    includes = config["include"]
    includes.keys.each do |p|
      @transactions.select { |t| t["description"].include? p }
        .each do |t|
          t["payee"] = includes[p]["payee"] if includes[p]["payee"]
          t["narration"] = includes[p]["narration"] if includes[p]["narration"]
          t["expense_account"] = includes[p]["account"] if includes[p]["account"]
        end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  file = ARGV[0]
  abort("Usage: ruby amex_detailer.rb FILE.json") unless file
  AmexDetailer.new(file).run
end
