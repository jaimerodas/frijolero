# frozen_string_literal: true

require "yaml"
require "fileutils"

module Frijolero
  class Config
    CONFIG_DIR = File.expand_path("~/.frijolero")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yaml")
    ACCOUNTS_FILE = File.join(CONFIG_DIR, "accounts.yaml")
    DETAILERS_DIR = File.join(CONFIG_DIR, "detailers")

    class << self
      def config_dir
        CONFIG_DIR
      end

      def config_file
        CONFIG_FILE
      end

      def accounts_file
        ACCOUNTS_FILE
      end

      def detailers_dir
        DETAILERS_DIR
      end

      def load
        @config ||= load_config
      end

      def reload!
        @config = nil
        @accounts = nil
      end

      def accounts
        @accounts ||= load_accounts
      end

      def openai_api_key
        load.dig("openai_api_key") || ENV["OPENAI_API_KEY"]
      end

      def openai_prompt(type = "default")
        load.dig("openai_prompts", type) ||
          load.dig("openai_prompts", "default") ||
          ENV["OPENAI_PROMPT_DEFAULT"]
      end

      def statements_input_dir
        expand_path(load.dig("paths", "statements_input")) ||
          ENV.fetch("STATEMENTS_INPUT_DIR", "./data/statements")
      end

      def statements_output_dir
        expand_path(load.dig("paths", "statements_output")) ||
          ENV.fetch("STATEMENTS_OUTPUT_DIR", "./data/output")
      end

      def beancount_main_file
        expand_path(load.dig("paths", "beancount_main")) ||
          ENV["BEANCOUNT_MAIN_FILE"]
      end

      def beancount_accounts_file
        expand_path(load.dig("paths", "beancount_accounts")) ||
          ENV["BEANCOUNT_ACCOUNTS_FILE"]
      end

      def detailer_config_path(account_name)
        return nil unless account_name

        config_name = account_name.downcase.gsub(" ", "_")
        File.join(DETAILERS_DIR, "#{config_name}.yaml")
      end

      def initialized?
        File.exist?(CONFIG_FILE)
      end

      private

      def load_config
        return {} unless File.exist?(CONFIG_FILE)

        YAML.load_file(CONFIG_FILE) || {}
      end

      def load_accounts
        return {} unless File.exist?(ACCOUNTS_FILE)

        YAML.load_file(ACCOUNTS_FILE) || {}
      end

      def expand_path(path)
        return nil unless path

        File.expand_path(path)
      end
    end
  end
end
