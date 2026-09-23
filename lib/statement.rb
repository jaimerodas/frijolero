# frozen_string_literal: true

require 'json'
require 'fileutils'

module Frijolero
  # One PDF's lifecycle: extract, save, detail, convert, merge, clean up. The job
  # knows the account and the period from the confirm page.
  class Statement
    NO_ACCOUNT_CONFIG = :no_account_config
    OVERWRITE_DECLINED = :overwrite_declined
    OK = :ok
    ERROR = :error

    def initialize(pdf_path, client:, s3:, account:, period:, overwrite: false)
      @pdf_path = pdf_path
      @client = client
      @s3 = s3
      @account_name = account
      @date_str = period
      @overwrite = overwrite
      @filename = File.basename(pdf_path)
    end

    # The account can be gone by the time the job runs: its first step is a pull.
    def process
      @account_config = AccountConfig.find_config(@account_name)
      unless @account_config
        Log.puts "{{x}} #{@filename}: No account configuration found for '#{@account_name}'"
        return NO_ACCOUNT_CONFIG
      end

      Log.puts "== Processing: #{@filename}"
      Log.puts "Account: #{@account_name}"
      return OVERWRITE_DECLINED if blocked_by_existing?

      run_pipeline
    end

    private

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

      Log.puts '{{!}} Existing files, not overwriting:'
      { 'JSON' => json, 'Beancount' => beancount }.select { |_, path| File.exist?(path) }.each do |label, path|
        Log.puts "  #{label}: #{Log.short_path(path)} (modified #{File.mtime(path).strftime('%Y-%m-%d %H:%M')})"
      end
      true
    end

    # The order is the point. S3 has the PDF before we pay for an extraction, and the
    # local copy outlives everything that can fail, so a failed job leaves a retry
    # sitting on disk instead of nothing at all.
    def run_pipeline
      pipeline = Pipeline.for(@account_config)
      back_up_pdf
      transactions = extract_transactions(pipeline)
      pipeline.validate!(transactions)
      discard_local_pdf

      Log.puts pipeline.summary(transactions)
      save_json(transactions)
      run_detailer if pipeline.runs_detailer?
      convert_to_beancount(pipeline)
      merge_into_ledger
      OK
    rescue *LLM::HANDLED => e
      LLM.report(e)
      ERROR
    rescue StandardError => e
      Log.puts "{{x}} ERROR processing #{@filename}: #{e.message}"
      ERROR
    end

    def back_up_pdf
      key = Config.pdf_key(@account_name, @date_str)
      @s3.put(key, @pdf_path)
      Log.puts "Saved PDF: #{key}"
    end

    def discard_local_pdf
      File.delete(@pdf_path)
      Log.puts 'Deleted local PDF'
    end

    def extract_transactions(pipeline)
      spec = pipeline.request_spec(Config.prompt_spec(@account_config['openai_prompt_type'] || 'default'))
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      transactions = @client.extract(@pdf_path, spec)
      Log.puts "Extracted transactions (#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round}s)"
      transactions
    end

    def save_json(transactions)
      FileUtils.mkdir_p(File.dirname(output_paths[:json]))
      File.write(output_paths[:json], JSON.pretty_generate(transactions))
      Log.puts "Saved JSON: #{Log.short_path(output_paths[:json])}"
    end

    def run_detailer
      yaml_path = Config.rules_path(@account_name)

      if yaml_path && File.exist?(yaml_path)
        stats = Detailer.new(output_paths[:json], yaml_path).run
        Log.detailer_stats(stats)
      else
        Log.puts '{{i}} No detailer config found, skipping enrichment'
      end
    end

    def convert_to_beancount(pipeline)
      FileUtils.mkdir_p(File.dirname(output_paths[:beancount]))
      pipeline.convert(json_path: output_paths[:json], output: output_paths[:beancount])
      Log.puts "Saved Beancount: #{Log.short_path(output_paths[:beancount])}"
    end

    def merge_into_ledger
      BeancountMerger.merge(output_paths[:beancount])
      Log.puts "Merged into: #{Log.short_path(Config.main_file)}"
    end
  end
end
