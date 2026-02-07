# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"

module Frijolero
  class StatementProcessor
    def initialize(dry_run: false, interactive: true)
      @dry_run = dry_run
      @input_dir = Config.statements_input_dir
      @output_dir = Config.statements_output_dir
      @client = OpenAIClient.new unless @dry_run
      UI.auto_accept = !interactive
    end

    def run
      ensure_directories
      pdf_files = Dir.glob(File.join(@input_dir, "*.pdf"))

      if pdf_files.empty?
        UI.puts "No PDF files found in #{@input_dir}"
        return
      end

      UI.puts "Found #{pdf_files.size} PDF(s) to process"
      UI.puts

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
      filename = File.basename(pdf_path)

      # Parse filename to extract account and date
      parsed = AccountConfig.parse_filename(pdf_path)

      unless parsed
        UI.puts "{{x}} #{filename}: Could not parse filename format"
        return
      end

      account_name, date_str = parsed
      account_config = AccountConfig.find_config(account_name)

      unless account_config
        UI.puts "{{x}} #{filename}: No account configuration found for '#{account_name}'"
        return
      end

      UI.frame("Processing: #{filename}") do
        UI.puts "Account: #{account_name}"

        if @dry_run
          UI.puts "{{i}} [DRY RUN] Would process this file"
          return
        end

        # Define output paths
        base_name = "#{account_name.gsub(" ", "_")}_#{date_str}"
        json_path = File.join(@output_dir, "json", "#{base_name}.json")
        beancount_path = File.join(@output_dir, "beancount", "#{base_name}.beancount")
        processed_path = File.join(@output_dir, "processed", File.basename(pdf_path))

        begin
          # Step 1: Upload PDF to OpenAI
          file_id = nil
          UI.spinner("Uploading to OpenAI...") do |spinner|
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            file_id = @client.upload_file(pdf_path)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            spinner.update_title("Uploaded to OpenAI (#{format_elapsed(elapsed)})")
          end

          # Step 2: Extract transactions
          transactions = nil
          prompt_id = get_prompt_id(account_config["openai_prompt_type"])
          UI.spinner("Extracting transactions...") do |spinner|
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            transactions = @client.extract_transactions(file_id, prompt_id)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            spinner.update_title("Extracted transactions (#{format_elapsed(elapsed)})")
          end

          tx_list = transactions["transactions"] || []
          UI.puts "Found #{tx_list.size} transactions#{transaction_summary(tx_list)}"

          # Step 3: Save JSON
          File.write(json_path, JSON.pretty_generate(transactions))
          UI.puts "Saved JSON: #{UI.short_path(json_path)}"

          # Step 4: Run detailer if config exists
          run_detailer(json_path, account_name)

          # Step 5: Convert to beancount (interactive)
          beancount_account = account_config["beancount_account"]
          if UI.confirm("Convert to Beancount (#{beancount_account})?")
            BeancountConverter.convert(
              input: json_path,
              account: beancount_account,
              output: beancount_path
            )
            UI.puts "Saved Beancount: #{UI.short_path(beancount_path)}"

            # Step 6: Merge into ledger (interactive)
            if UI.confirm("Merge into ledger?")
              main_file = Config.beancount_main_file
              if main_file
                BeancountMerger.new(files: [beancount_path], quiet: true).run
                UI.puts "Merged into: #{UI.short_path(main_file)}"
              else
                UI.puts "{{i}} No main ledger configured (set paths.beancount_main in config)"
              end
            end
          else
            UI.puts "{{i}} Skipped Beancount conversion"
          end

          # Step 7: Delete file from OpenAI (silent)
          @client.delete_file(file_id)

          # Step 8: Move processed PDF
          FileUtils.mv(pdf_path, processed_path)
          UI.puts "Moved PDF to: #{UI.short_path(processed_path)}"
        rescue => e
          UI.puts "{{x}} ERROR: #{e.message}"
          if defined?(file_id) && file_id
            begin
              @client.delete_file(file_id)
            rescue
              # Ignore cleanup errors
            end
          end
        end
      end
    end

    def get_prompt_id(prompt_type)
      Config.openai_prompt(prompt_type || "default")
    end

    def run_detailer(json_path, account_name)
      yaml_path = Config.detailer_config_path(account_name)

      if yaml_path && File.exist?(yaml_path)
        stats = Detailer.new(json_path, yaml_path).run
        UI.puts "#{stats[:detailed]} transactions detailed, #{stats[:remaining]} remaining"
      else
        UI.puts "{{i}} No detailer config found, skipping enrichment"
      end
    end

    def format_elapsed(seconds)
      if seconds < 60
        "#{seconds.round(1)}s"
      else
        mins = (seconds / 60).floor
        secs = (seconds % 60).round(1)
        "#{mins}m #{secs}s"
      end
    end

    def transaction_summary(transactions)
      return "" if transactions.empty?

      debits = transactions.select { |t| t["amount"].to_f < 0 }
      credits = transactions.select { |t| t["amount"].to_f >= 0 }

      parts = []
      if debits.any?
        total = debits.sum { |t| t["amount"].to_f.abs }
        parts << "#{debits.size} debits (#{UI.format_number(total)})"
      end
      if credits.any?
        total = credits.sum { |t| t["amount"].to_f }
        parts << "#{credits.size} credits (#{UI.format_number(total)})"
      end

      ": #{parts.join(", ")}"
    end
  end
end
