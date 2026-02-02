require 'json'

class BaseDetailer
  def initialize(file)
    @file = file
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
    raise "You need to implement this"
  end

  def write_file
    File.write(file, JSON.pretty_generate({"transactions" => @transactions}))
  end
end
