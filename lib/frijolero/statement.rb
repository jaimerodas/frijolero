# frozen_string_literal: true

require 'json'
require 'fileutils'

module Frijolero
  class Statement
    UNPARSEABLE = :unparseable
    NO_ACCOUNT_CONFIG = :no_account_config
    OVERWRITE_DECLINED = :overwrite_declined
    OK = :ok
    ERROR = :error

    DRY_RUN = :dry_run

    def initialize(pdf_path, client:, output_dir:, dry_run: false)
      @pdf_path = pdf_path
      @client = client
      @output_dir = output_dir
      @dry_run = dry_run
      @filename = File.basename(pdf_path)
    end

    def process
      status = load_metadata
      return status unless status == OK

      result = nil
      UI.frame("Processing: #{@filename}") do
        UI.puts "Account: #{@account_name}"
        result = process_inside_frame
      end
      result
    end

    private

    attr_reader :client

    def process_inside_frame
      if @dry_run
        UI.puts '{{i}} [DRY RUN] Would process this file'
        return DRY_RUN
      end

      ok = check_overwrite(output_paths[:json], output_paths[:beancount])
      ok ? run_pipeline : OVERWRITE_DECLINED
    end

    def load_metadata
      parsed = AccountConfig.parse_filename(@pdf_path)
      unless parsed
        UI.puts "{{x}} #{@filename}: Could not parse filename format"
        return UNPARSEABLE
      end

      @account_name, @date_str = parsed
      @account_config = AccountConfig.find_config(@account_name)
      unless @account_config
        UI.puts "{{x}} #{@filename}: No account configuration found for '#{@account_name}'"
        return NO_ACCOUNT_CONFIG
      end

      # Use the canonical account name from accounts.yaml so output paths are
      # consistent regardless of how the PDF filename was capitalized.
      @account_name = AccountConfig.canonical_account_name(@account_name) || @account_name
      OK
    end

    def output_paths
      @output_paths ||= begin
        safe_account = @account_name.gsub(' ', '_')
        base = "#{safe_account}_#{@date_str}"
        account_dir = File.join(@output_dir, safe_account)
        {
          beancount: File.join(account_dir, "#{base}.beancount"),
          json: File.join(account_dir, 'json', "#{base}.json"),
          pdf: File.join(account_dir, 'pdf', "#{base}.pdf")
        }
      end
    end

    def check_overwrite(json_path, beancount_path)
      existing = [json_path, beancount_path].select { |p| File.exist?(p) }
      return true if existing.empty?

      UI.puts '{{!}} Existing files will be overwritten:'
      show_existing_json_info(json_path) if File.exist?(json_path)
      show_existing_beancount_info(beancount_path) if File.exist?(beancount_path)
      UI.confirm('Overwrite existing files?', default: false)
    end

    def show_existing_json_info(json_path)
      mtime = File.mtime(json_path).strftime('%Y-%m-%d %H:%M')
      contents = JsonStatementSummary.describe(json_path)
      UI.puts "  JSON: #{UI.short_path(json_path)} (modified #{mtime})"
      UI.puts "  Contains: #{contents}"
    rescue JSON::ParserError
      UI.puts "  JSON: #{UI.short_path(json_path)} (modified #{mtime}, could not parse)"
    end

    def show_existing_beancount_info(beancount_path)
      mtime = File.mtime(beancount_path).strftime('%Y-%m-%d %H:%M')
      UI.puts "  Beancount: #{UI.short_path(beancount_path)} (modified #{mtime})"
    end

    def run_pipeline
      file_id = upload_pdf
      transactions = extract_transactions(file_id)
      pipeline = Pipeline.for(@account_config)

      UI.puts pipeline.summary(transactions)
      save_json(transactions)
      run_detailer if pipeline.runs_detailer?
      convert_and_merge(pipeline) if UI.confirm("Convert to Beancount (#{pipeline.beancount_account})?")
      finalize(file_id)
      OK
    rescue *OpenAIErrorReporter::HANDLED => e
      OpenAIErrorReporter.handle(e, client: client, file_id: file_id)
      ERROR
    rescue StandardError => e
      UI.puts "{{x}} ERROR processing #{@filename}: #{e.message}"
      OpenAIErrorReporter.cleanup(client, file_id)
      ERROR
    end

    def upload_pdf
      file_id = nil
      UI.spinner('Uploading to OpenAI...') do |spinner|
        elapsed = measure { file_id = client.upload_file(@pdf_path) }
        spinner.update_title("Uploaded to OpenAI (#{format_elapsed(elapsed)})")
      end
      file_id
    end

    def extract_transactions(file_id)
      transactions = nil
      prompt_id = Config.openai_prompt(@account_config['openai_prompt_type'] || 'default')
      UI.spinner('Extracting transactions...') do |spinner|
        elapsed = measure { transactions = client.extract_transactions(file_id, prompt_id) }
        spinner.update_title("Extracted transactions (#{format_elapsed(elapsed)})")
      end
      transactions
    end

    def save_json(transactions)
      FileUtils.mkdir_p(File.dirname(output_paths[:json]))
      File.write(output_paths[:json], JSON.pretty_generate(transactions))
      UI.puts "Saved JSON: #{UI.short_path(output_paths[:json])}"
    end

    def run_detailer
      yaml_path = Config.detailer_config_path(@account_name)

      if yaml_path && File.exist?(yaml_path)
        stats = Detailer.new(output_paths[:json], yaml_path).run
        UI.detailer_stats(stats)
      else
        UI.puts '{{i}} No detailer config found, skipping enrichment'
      end
    end

    def convert_and_merge(pipeline)
      convert_to_beancount(pipeline)
      merge_into_ledger if UI.confirm('Merge into ledger?')
    end

    def convert_to_beancount(pipeline)
      FileUtils.mkdir_p(File.dirname(output_paths[:beancount]))
      pipeline.convert(json_path: output_paths[:json], output: output_paths[:beancount])
      UI.puts "Saved Beancount: #{UI.short_path(output_paths[:beancount])}"
    end

    def merge_into_ledger
      main_file = Config.beancount_main_file
      unless main_file
        UI.puts '{{i}} No main ledger configured (set paths.beancount_main in config)'
        return
      end

      BeancountMerger.new(files: [output_paths[:beancount]], quiet: true).run
      UI.puts "Merged into: #{UI.short_path(main_file)}"
    end

    def finalize(file_id)
      client.delete_file(file_id)
      FileUtils.mkdir_p(File.dirname(output_paths[:pdf]))
      FileUtils.mv(@pdf_path, output_paths[:pdf])
      UI.puts "Moved PDF to: #{UI.short_path(output_paths[:pdf])}"
    end

    def measure
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    def format_elapsed(seconds)
      return "#{seconds.round(1)}s" if seconds < 60

      mins = (seconds / 60).floor
      secs = (seconds % 60).round(1)
      "#{mins}m #{secs}s"
    end
  end
end
