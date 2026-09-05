# frozen_string_literal: true

require 'json'
require 'fileutils'

module Frijolero
  # One PDF's lifecycle: resolve metadata, extract, save, detail, convert, merge, clean up.
  # The caller (a background job) usually already knows the account, the period and the
  # OpenAI file id; the filename is only the fallback.
  class Statement
    UNPARSEABLE = :unparseable
    NO_ACCOUNT_CONFIG = :no_account_config
    OVERWRITE_DECLINED = :overwrite_declined
    OK = :ok
    ERROR = :error

    DRY_RUN = :dry_run

    def initialize(pdf_path, client:, account: nil, period: nil, file_id: nil, overwrite: false, dry_run: false)
      @pdf_path = pdf_path
      @client = client
      @account_name = account
      @date_str = period
      @file_id = file_id
      @overwrite = overwrite
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

      return OVERWRITE_DECLINED if blocked_by_existing?

      run_pipeline
    end

    def load_metadata
      @account_name, @date_str = AccountConfig.parse_filename(@pdf_path) unless @account_name && @date_str

      unless @account_name && @date_str
        UI.puts "{{x}} #{@filename}: Could not parse filename format"
        return UNPARSEABLE
      end

      @account_config = AccountConfig.find_config(@account_name)
      return OK if @account_config

      UI.puts "{{x}} #{@filename}: No account configuration found for '#{@account_name}'"
      NO_ACCOUNT_CONFIG
    end

    def output_paths
      @output_paths ||= {
        beancount: Config.statement_path(@account_name, @date_str, 'beancount'),
        json: Config.statement_path(@account_name, @date_str, 'json')
      }
    end

    # There is no terminal to ask, so the caller decides with overwrite:.
    def blocked_by_existing?
      return false if @overwrite

      json, beancount = output_paths.values_at(:json, :beancount)
      return false unless File.exist?(json) || File.exist?(beancount)

      UI.puts '{{!}} Existing files, not overwriting:'
      show_existing_json_info(json) if File.exist?(json)
      show_existing_beancount_info(beancount) if File.exist?(beancount)
      true
    end

    def show_existing_json_info(json_path)
      mtime = File.mtime(json_path).strftime('%Y-%m-%d %H:%M')
      UI.puts "  JSON: #{UI.short_path(json_path)} (modified #{mtime})"
    end

    def show_existing_beancount_info(beancount_path)
      mtime = File.mtime(beancount_path).strftime('%Y-%m-%d %H:%M')
      UI.puts "  Beancount: #{UI.short_path(beancount_path)} (modified #{mtime})"
    end

    def run_pipeline
      file_id = @file_id || upload_pdf
      transactions = extract_transactions(file_id)
      pipeline = Pipeline.for(@account_config)

      UI.puts pipeline.summary(transactions)
      save_json(transactions)
      run_detailer if pipeline.runs_detailer?
      convert_to_beancount(pipeline)
      merge_into_ledger
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
      spec = Config.openai_prompt_spec(@account_config['openai_prompt_type'] || 'default')
      UI.spinner('Extracting transactions...') do |spinner|
        elapsed = measure { transactions = client.extract_transactions(file_id, spec) }
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
      yaml_path = Config.rules_path(@account_name)

      if yaml_path && File.exist?(yaml_path)
        stats = Detailer.new(output_paths[:json], yaml_path).run
        UI.detailer_stats(stats)
      else
        UI.puts '{{i}} No detailer config found, skipping enrichment'
      end
    end

    def convert_to_beancount(pipeline)
      FileUtils.mkdir_p(File.dirname(output_paths[:beancount]))
      pipeline.convert(json_path: output_paths[:json], output: output_paths[:beancount])
      UI.puts "Saved Beancount: #{UI.short_path(output_paths[:beancount])}"
    end

    def merge_into_ledger
      BeancountMerger.new(files: [output_paths[:beancount]], quiet: true).run
      UI.puts "Merged into: #{UI.short_path(Config.main_file)}"
    end

    # The job ends here, so the uploaded PDF goes away here too, whether we uploaded it
    # or the caller did.
    def finalize(file_id)
      client.delete_file(file_id)
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
