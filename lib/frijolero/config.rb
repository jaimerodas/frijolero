# frozen_string_literal: true

require 'yaml'

module Frijolero
  class Config
    class << self
      def ledger_dir
        ENV.fetch('LEDGER_DIR') { raise 'LEDGER_DIR is not set' }
      end

      def main_file
        File.join(ledger_dir, ENV.fetch('LEDGER_MAIN_FILE', 'transactions.beancount'))
      end

      def config_dir
        File.join(ledger_dir, 'config')
      end

      def accounts_file
        File.join(config_dir, 'accounts.yaml')
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

      def accounts
        @accounts ||= load_accounts
      end

      def reload!
        @accounts = nil
      end

      def openai_api_key
        ENV.fetch('OPENAI_API_KEY', nil)
      end

      # Seconds to keep polling a background extraction before giving up. Background
      # responses are retained by OpenAI for ~10 minutes, so values beyond that risk the
      # result expiring server-side. Override via OPENAI_POLL_TIMEOUT.
      def openai_poll_timeout
        value = ENV.fetch('OPENAI_POLL_TIMEOUT', nil)
        value ? value.to_i : OpenAIClient::POLL_TIMEOUT_SECONDS
      end

      # Assembles the inline OpenAI prompt spec from prompts/<type>/ (see PromptSpec).
      def openai_prompt_spec(type = 'default')
        PromptSpec.load(type, prompts_dir)
      end

      private

      def load_accounts
        return {} unless File.exist?(accounts_file)

        YAML.load_file(accounts_file) || {}
      end
    end
  end
end
