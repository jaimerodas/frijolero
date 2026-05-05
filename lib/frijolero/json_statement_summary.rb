# frozen_string_literal: true

require 'json'

module Frijolero
  module JsonStatementSummary
    def self.describe(json_path)
      data = JSON.parse(File.read(json_path))
      return summarize_transactions(data['transactions']) if data['transactions']
      return summarize_movements(data['movements']) if data['movements']

      'empty'
    end

    def self.summarize_transactions(tx_list)
      return 'empty' if tx_list.empty?

      "#{tx_list.size} transactions#{UI.transaction_summary(tx_list)}#{format_date_range(tx_list)}"
    end

    def self.summarize_movements(movements)
      return 'empty' if movements.empty?

      "#{movements.size} movements"
    end

    def self.format_date_range(tx_list)
      dates = tx_list.filter_map { |t| t['date'] }.sort
      return '' if dates.empty?

      " (#{dates.first} to #{dates.last})"
    end
  end
end
