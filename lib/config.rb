# frozen_string_literal: true

require 'yaml'

module Frijolero
  class Config
    class << self
      def ledger_dir
        ENV.fetch('LEDGER_DIR') { raise 'LEDGER_DIR is not set' }
      end

      # The one file the app knows by name: it appends the includes (and, without a
      # separate opens file, the opens) to it, and the reports read it.
      def main_file
        File.join(ledger_dir, ENV.fetch('LEDGER_MAIN_FILE', 'main.beancount'))
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

      def report_file = main_file

      # The brand and the default page title: the ledger's own `option "title"`,
      # or the app's name. Read on each call, like `accounts`.
      def title
        (File.exist?(main_file) && File.read(main_file)[/^option "title" "(.+)"/, 1]) || 'Frijolero'
      end

      def rledger
        ENV.fetch('RLEDGER', 'rledger')
      end

      def rules_dir
        File.join(config_dir, 'rules')
      end

      def prompts_dir
        File.join(config_dir, 'prompts')
      end

      def rules_path(account_key)
        return nil unless account_key

        File.join(rules_dir, "#{account_key}.yaml")
      end

      def statement_path(account_key, period, ext)
        File.join(ledger_dir, 'accounts', account_key, "#{account_key} #{period}.#{ext}")
      end

      # The S3 bucket mirrors the ledger's own layout, so one key formula serves both
      # the upload and the signed download. Spaces stay literal here; percent-encoding
      # is the signer's job (S3#host_and_path).
      # The bucket is shared with other apps, so every key lives under frijolero/.
      S3_PREFIX = 'frijolero'

      def pdf_prefix(account_key)
        "#{S3_PREFIX}/accounts/#{account_key}/"
      end

      def pdf_key(account_key, period)
        "#{pdf_prefix(account_key)}#{account_key} #{period}.pdf"
      end

      # Read on every call, never cached: a `git pull` or the accounts editor can
      # change the file under a running app, and the file is tiny.
      def accounts
        return {} unless File.exist?(accounts_file)

        YAML.load_file(accounts_file) || {}
      end

      def data_dir
        File.dirname(ledger_dir)
      end

      def jobs_file
        File.join(data_dir, 'jobs.jsonl')
      end

      def incoming_dir
        File.join(data_dir, 'incoming')
      end

      # The PDFs when S3 is not set (LocalPdfs).
      def pdfs_dir
        File.join(data_dir, 'pdfs')
      end

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
