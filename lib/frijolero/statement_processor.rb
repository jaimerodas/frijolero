# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"

module Frijolero
  class StatementProcessor
    def initialize(dry_run: false)
      @dry_run = dry_run
      @input_dir = Config.statements_input_dir
      @output_dir = Config.statements_output_dir
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
      parsed = AccountConfig.parse_filename(pdf_path)

      unless parsed
        puts "  SKIP: Could not parse filename format"
        puts
        return
      end

      account_name, date_str = parsed
      account_config = AccountConfig.find_config(account_name)

      unless account_config
        puts "  SKIP: No account configuration found for '#{account_name}'"
        puts
        return
      end

      puts "  Account: #{account_name}"
      puts "  Beancount: #{account_config["beancount_account"]}"
      puts "  Date: #{date_str}"

      if @dry_run
        puts "  [DRY RUN] Would process this file"
        puts
        return
      end

      # Define output paths
      base_name = "#{account_name.gsub(" ", "_")}_#{date_str}"
      json_path = File.join(@output_dir, "json", "#{base_name}.json")
      beancount_path = File.join(@output_dir, "beancount", "#{base_name}.beancount")
      processed_path = File.join(@output_dir, "processed", File.basename(pdf_path))

      begin
        # Step 1: Upload PDF to OpenAI
        puts "  Uploading to OpenAI..."
        file_id = @client.upload_file(pdf_path)
        puts "  File ID: #{file_id}"

        # Step 2: Extract transactions
        print "  Extracting transactions"
        prompt_id = get_prompt_id(account_config["openai_prompt_type"])
        transactions = @client.extract_transactions(file_id, prompt_id)
        transaction_list = transactions["transactions"] || []
        puts "  Found #{transaction_list.size} transactions"
        report_transaction_totals(transaction_list)

        # Step 3: Save JSON
        File.write(json_path, JSON.pretty_generate(transactions))
        puts "  Saved JSON: #{json_path}"

        # Step 4: Run detailer if config exists
        run_detailer(json_path, account_name)

        # Step 5: Convert to beancount
        puts "  Converting to Beancount..."
        BeancountConverter.convert(
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

    def get_prompt_id(prompt_type)
      Config.openai_prompt(prompt_type || "default")
    end

    def run_detailer(json_path, account_name)
      yaml_path = Config.detailer_config_path(account_name)

      if yaml_path && File.exist?(yaml_path)
        puts "  Running detailer with #{yaml_path}..."
        result = Detailer.new(json_path, yaml_path).run
        puts "  Metadata enriched on #{result[:metadata_enriched]} transaction(s)"
        puts "  Transactions still missing metadata: #{result[:metadata_remaining]}"
      else
        puts "  No detailer config found, skipping enrichment"
      end
    end

    def report_transaction_totals(transactions)
      positive_total = transactions.sum do |transaction|
        amount = transaction.fetch("amount", 0).to_f
        amount.positive? ? amount : 0
      end

      negative_total = transactions.sum do |transaction|
        amount = transaction.fetch("amount", 0).to_f
        amount.negative? ? amount : 0
      end

      puts "  Credits total: #{format_amount(positive_total)}"
      puts "  Debits total: #{format_amount(negative_total)}"
    end

    def format_amount(amount)
      formatted = format("%.2f", amount)
      integer_part, decimal_part = formatted.split(".", 2)
      sign = integer_part.start_with?("-") ? "-" : ""
      digits = sign.empty? ? integer_part : integer_part[1..]
      with_separators = digits.reverse.scan(/\d{1,3}/).join(",").reverse
      "#{sign}#{with_separators}.#{decimal_part}"
    end
  end
end
