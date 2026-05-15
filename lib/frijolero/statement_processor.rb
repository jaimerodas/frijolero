# frozen_string_literal: true

module Frijolero
  class StatementProcessor
    def initialize(dry_run: false, interactive: true, client: nil)
      @dry_run = dry_run
      @input_dir = Config.statements_input_dir
      @output_dir = Config.statements_output_dir
      @client = client || (OpenAIClient.new unless @dry_run)
      UI.auto_accept = !interactive
    end

    def run
      pdf_files = Dir.glob(File.join(@input_dir, '*.pdf'))

      if pdf_files.empty?
        UI.puts "No PDF files found in #{@input_dir}"
        return
      end

      UI.puts "Found #{pdf_files.size} PDF(s) to process"
      UI.puts

      pdf_files.each { |pdf_path| process_pdf(pdf_path) }
    rescue OpenAIClient::InsufficientQuotaError, OpenAIClient::AuthenticationError
      UI.puts '{{x}} Aborted batch.'
    end

    private

    def process_pdf(pdf_path)
      Statement.new(pdf_path, client: @client, output_dir: @output_dir, dry_run: @dry_run).process
    end
  end
end
