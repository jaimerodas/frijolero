#!/usr/bin/env ruby
# frozen_string_literal: true

require 'dotenv/load'
require 'yaml'
require 'json'
require 'fileutils'
require_relative 'openai_client'
require_relative 'generic_detailer'
require_relative 'json_to_beancount'

class StatementProcessor
  def initialize(dry_run: false)
    @dry_run = dry_run
    @input_dir = ENV.fetch("STATEMENTS_INPUT_DIR", "./data/statements")
    @output_dir = ENV.fetch("STATEMENTS_OUTPUT_DIR", "./data/output")
    @accounts = YAML.load_file("config/accounts.yaml")
    @client = OpenAIClient.new unless @dry_run
  end

  def run
    ensure_directories
    pdf_files = Dir.glob(File.join(@input_dir, "*.pdf"))

    if pdf_files.empty?
      puts "No PDF files found in #{@input_dir}"
      return
    end

    puts "Found #{pdf_files.size} PDF(s) to process"
    puts

    pdf_files.each do |pdf_path|
      process_pdf(pdf_path)
    end
  end

  private

  def ensure_directories
    %w[json beancount processed].each do |subdir|
      dir = File.join(@output_dir, subdir)
      FileUtils.mkdir_p(dir) unless @dry_run
    end
  end

  def process_pdf(pdf_path)
    filename = File.basename(pdf_path, ".pdf")
    puts "Processing: #{filename}"

    # Parse filename to extract account and date
    account_name, date_str = parse_filename(filename)

    unless account_name
      puts "  SKIP: Could not parse filename format"
      puts
      return
    end

    account_config = find_account_config(account_name)

    unless account_config
      puts "  SKIP: No account configuration found for '#{account_name}'"
      puts
      return
    end

    puts "  Account: #{account_name}"
    puts "  Beancount: #{account_config['beancount_account']}"
    puts "  Date: #{date_str}"

    if @dry_run
      puts "  [DRY RUN] Would process this file"
      puts
      return
    end

    # Define output paths
    base_name = "#{account_name.gsub(' ', '_')}_#{date_str}"
    json_path = File.join(@output_dir, "json", "#{base_name}.json")
    beancount_path = File.join(@output_dir, "beancount", "#{base_name}.beancount")
    processed_path = File.join(@output_dir, "processed", File.basename(pdf_path))

    begin
      # Step 1: Upload PDF to OpenAI
      puts "  Uploading to OpenAI..."
      file_id = @client.upload_file(pdf_path)
      puts "  File ID: #{file_id}"

      # Step 2: Extract transactions
      puts "  Extracting transactions..."
      prompt_id = get_prompt_id(account_config["openai_prompt_type"])
      transactions = @client.extract_transactions(file_id, prompt_id)
      puts "  Found #{transactions['transactions']&.size || 0} transactions"

      # Step 3: Save JSON
      File.write(json_path, JSON.pretty_generate(transactions))
      puts "  Saved JSON: #{json_path}"

      # Step 4: Run detailer if config exists
      run_detailer(json_path, account_name)

      # Step 5: Convert to beancount
      puts "  Converting to Beancount..."
      JsonToBeancount.convert(
        input: json_path,
        account: account_config["beancount_account"],
        output: beancount_path
      )
      puts "  Saved Beancount: #{beancount_path}"

      # Step 6: Delete file from OpenAI
      puts "  Cleaning up OpenAI file..."
      @client.delete_file(file_id)

      # Step 7: Move processed PDF
      FileUtils.mv(pdf_path, processed_path)
      puts "  Moved PDF to: #{processed_path}"

      puts "  Done!"
    rescue => e
      puts "  ERROR: #{e.message}"
      # Try to clean up the uploaded file if we have a file_id
      if defined?(file_id) && file_id
        begin
          @client.delete_file(file_id)
        rescue
          # Ignore cleanup errors
        end
      end
    end

    puts
  end

  def parse_filename(filename)
    # Expected format: "Account Name YYMM" (e.g., "Amex 2501" or "BBVA TDC 2501")
    match = filename.match(/^(.+?)\s+(\d{4})$/)
    return nil unless match

    [match[1], match[2]]
  end

  def find_account_config(account_name)
    # Try exact match first
    return @accounts[account_name] if @accounts[account_name]

    # Try case-insensitive match
    @accounts.find { |k, _| k.downcase == account_name.downcase }&.last
  end

  def get_prompt_id(prompt_type)
    case prompt_type
    when "bbva"
      ENV.fetch("OPENAI_PROMPT_BBVA")
    else
      ENV.fetch("OPENAI_PROMPT_DEFAULT")
    end
  end

  def run_detailer(json_path, account_name)
    config_name = account_name.downcase.gsub(" ", "_")
    yaml_path = "config/#{config_name}.yaml"

    if File.exist?(yaml_path)
      puts "  Running detailer with #{yaml_path}..."
      GenericDetailer.new(json_path, yaml_path).run
    else
      puts "  No detailer config found, skipping enrichment"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  dry_run = ARGV.include?("--dry-run")

  if ARGV.include?("--help") || ARGV.include?("-h")
    puts <<~HELP
      Usage: ruby process_statements.rb [OPTIONS]

      Process PDF bank/credit card statements through the pipeline:
        1. Upload PDF to OpenAI
        2. Extract transactions using stored prompts
        3. Enrich with detailer rules (if available)
        4. Convert to Beancount format

      Options:
        --dry-run    Show what would be processed without making changes
        --help, -h   Show this help message

      Configuration:
        - Set environment variables in .env (copy from .env.example)
        - Configure accounts in accounts.yaml
        - Place PDF statements in STATEMENTS_INPUT_DIR

      Filename format:
        PDFs should be named: "Account Name YYMM.pdf"
        Examples: "Amex 2501.pdf", "BBVA TDC 2501.pdf"
    HELP
    exit 0
  end

  StatementProcessor.new(dry_run: dry_run).run
end
