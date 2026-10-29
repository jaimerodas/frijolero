# frozen_string_literal: true

require 'yaml'

module Frijolero
  # The paths and settings of the current ledger (Ledger.current), and the few that are
  # global. Without a current ledger, a ledger path raises NoLedger.
  class Config
    # An account key is a directory of the ledger and the start of its file names, so it
    # holds no `/` and it is not `.` or `..`.
    ACCOUNT_KEY = /\A(?!\.\.?\z)[\p{L}\p{N} ._-]+\z/

    class << self
      # The volume: the database, and ledgers/<id>/ for each ledger.
      def data_dir
        ENV.fetch('DATA_DIR') { raise 'DATA_DIR is not set' }
      end

      def ledger_dir = Ledger.current.repo_dir

      # The one file the app knows by name: it appends the includes (and, without a
      # separate opens file, the opens) to it, and the reports read it.
      def main_file
        File.join(ledger_dir, Ledger.current.main_file)
      end

      def config_dir
        File.join(ledger_dir, 'config')
      end

      def accounts_file
        File.join(config_dir, 'accounts.yaml')
      end

      # A ledger that keeps its opens apart has account_opens.beancount; the rest go
      # to the main file. Beancount does not care which file an entry is in.
      def account_opens_file
        separate = File.join(ledger_dir, 'account_opens.beancount')
        File.exist?(separate) ? separate : main_file
      end

      def rledger
        ENV.fetch('RLEDGER', 'rledger')
      end

      def rules_dir
        File.join(config_dir, 'rules')
      end

      # The prompts belong to the app, not to a ledger: the app pays for the model, so it
      # picks the models, and an improved prompt reaches every ledger.
      def prompts_dir = File.expand_path('../prompts', __dir__)

      def rules_path(account_key)
        return nil unless account_key

        File.join(rules_dir, "#{account_key}.yaml")
      end

      def statement_path(account_key, period, ext)
        File.join(ledger_dir, 'accounts', account_key, "#{account_key} #{period}.#{ext}")
      end

      # The periods that have a `.beancount` for this account, oldest first.
      def statement_periods(account_key)
        name = /\A#{Regexp.escape(account_key)} (\d{4})\.beancount\z/
        Dir.children(File.join(ledger_dir, 'accounts', account_key)).filter_map { |file| name.match(file)&.[](1) }.sort
      end

      # The S3 bucket mirrors the ledger's own layout, so one key formula serves both
      # the upload and the signed download. Spaces stay literal here; percent-encoding
      # is the signer's job (S3#host_and_path).
      # The bucket is shared with other apps, so every ledger's pdf_prefix is under frijolero/.
      def pdf_prefix(account_key)
        "#{Ledger.current.pdf_prefix}/accounts/#{account_key}/"
      end

      def pdf_key(account_key, period)
        "#{pdf_prefix(account_key)}#{account_key} #{period}.pdf"
      end

      # Read on every call, never cached: a `git pull` or the accounts editor can
      # change the file under a running app, and the file is tiny. A key that is not an
      # ACCOUNT_KEY is left out, so no path is ever made from it.
      def accounts
        return {} unless File.exist?(accounts_file)

        (YAML.load_file(accounts_file) || {}).select { |key, _| account_key?(key) }
      end

      def account_key?(key) = key.is_a?(String) && key.match?(ACCOUNT_KEY)

      def jobs_file = File.join(Ledger.current.dir, 'jobs.jsonl')

      def incoming_dir = File.join(Ledger.current.dir, 'incoming')

      # The PDFs when S3 is not set (LocalPdfs).
      def pdfs_dir = File.join(Ledger.current.dir, 'pdfs')

      # Seconds to wait for one extraction: OpenAI's poll deadline (background
      # responses are kept for about 10 minutes) and Anthropic's read timeout.
      def llm_timeout = ENV.fetch('LLM_TIMEOUT', 900).to_i

      # Assembles the prompt spec from prompts/<type>/ (see PromptSpec).
      def prompt_spec(type = 'default')
        PromptSpec.load(type, prompts_dir)
      end
    end
  end
end
