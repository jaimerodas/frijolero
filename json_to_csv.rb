require 'json'
require 'date'
require 'optparse'
require 'csv'

options = {}

parser = OptionParser.new do |opts|
  opts.banner = <<~BANNER
    Usage: json_to_csv.rb \
      -i input.json \
      -o output.csv
  BANNER

  opts.on("-i", "--input FILE", "Input JSON file") do |v|
    options[:input] = v
  end

  opts.on("-o", "--output FILE", "Output CSV file") do |v|
    options[:output] = v
  end
end

parser.parse!

required = [:input]
missing = required.select { |k| options[k].nil? }

unless missing.empty?
  puts "Missing required options: #{missing.join(', ')}"
  puts parser
  exit 1
end

output = options[:output] || options[:input].sub(/\.json\z/, ".csv")

json = JSON.parse(File.read(options[:input]))

CSV.open(output, "w", write_headers: true, headers: ["Date", "Description", "Amount"]) do |csv|
  json["transactions"].each do |tx|
    date        = Date.parse(tx["date"]).strftime("%Y-%m-%d")
    description = (tx["description"] || "").gsub(/\s+/, " ").strip
    amount      = tx["amount"].to_f

    csv << [date, description, amount]
  end
end
