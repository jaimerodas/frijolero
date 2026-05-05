# frozen_string_literal: true

require 'json'
require 'date'
require 'csv'

module Frijolero
  module CsvConverter
    HEADERS = %w[Date Description Amount].freeze

    def self.convert(input:, output: nil)
      raise ArgumentError, 'input file required' unless input

      output ||= input.sub(/\.json\z/, '.csv')
      transactions = JSON.parse(File.read(input))['transactions']

      CSV.open(output, 'w', write_headers: true, headers: HEADERS) do |csv|
        transactions.each { |transaction| csv << format_row(transaction) }
      end

      output
    end

    def self.format_row(transaction)
      [
        Date.parse(transaction['date']).strftime('%Y-%m-%d'),
        (transaction['description'] || '').gsub(/\s+/, ' ').strip,
        transaction['amount'].to_f
      ]
    end
  end
end
