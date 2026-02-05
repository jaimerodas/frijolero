# frozen_string_literal: true

require "json"
require "date"
require "csv"

module Frijolero
  module CsvConverter
    def self.convert(input:, output: nil)
      raise ArgumentError, "input file required" unless input

      output ||= input.sub(/\.json\z/, ".csv")

      json = JSON.parse(File.read(input))

      CSV.open(output, "w", write_headers: true, headers: ["Date", "Description", "Amount"]) do |csv|
        json["transactions"].each do |tx|
          date = Date.parse(tx["date"]).strftime("%Y-%m-%d")
          description = (tx["description"] || "").gsub(/\s+/, " ").strip
          amount = tx["amount"].to_f

          csv << [date, description, amount]
        end
      end

      output
    end
  end
end
