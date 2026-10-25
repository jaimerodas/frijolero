# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'time'

module Frijolero
  # From the single-user layout to ledgers/<id>/. Before, DATA_DIR held one ledger
  # (LEDGER_DIR, by default DATA_DIR/ledger) with jobs.jsonl, incoming/ and pdfs/ next
  # to it. At boot, this makes the admin from ADMIN_EMAIL when there is none, and adopts
  # that ledger when there are no ledgers: one row, and each file moved by a rename on
  # the same volume. A second run finds the rows and does nothing.
  module Migration
    NEXT_TO_THE_LEDGER = %w[jobs.jsonl incoming pdfs].freeze

    class << self
      def run
        owner = admin_id
        adopt(owner) if Ledger.all.empty? && File.directory?(legacy_dir)
      end

      private

      def admin_id
        row = DB.first("SELECT id FROM users WHERE role = 'admin' ORDER BY id")
        return row['id'] if row

        email = ENV.fetch('ADMIN_EMAIL') { raise 'ADMIN_EMAIL is not set: the first admin needs it' }
        DB.insert("INSERT INTO users (email, role, status, created_at) VALUES (?, 'admin', 'active', ?)", email, now)
      end

      def legacy_dir = ENV.fetch('LEDGER_DIR') { File.join(Config.data_dir, 'ledger') }

      # The PDFs keep their keys: this ledger's pdf_prefix is the one every key had,
      # frijolero. The iOS Shortcut keeps its token.
      def adopt(owner)
        main_file = ENV.fetch('LEDGER_MAIN_FILE', 'main.beancount')
        main = File.join(legacy_dir, main_file)
        raise missing_main_file(main) unless File.exist?(main)

        id = Ledger.new_id
        DB.transaction do
          DB.execute('INSERT INTO ledgers (id, owner_id, name, main_file, pdf_prefix, created_at) ' \
                     "VALUES (?, ?, ?, ?, 'frijolero', ?)", id, owner, title(main), main_file, now)
          add_api_token(id)
          move(File.join(Config.data_dir, 'ledgers', id))
        end
      end

      def add_api_token(ledger_id)
        token = ENV.fetch('API_TOKEN', '')
        return if token.empty?

        DB.execute("INSERT INTO api_tokens (token_sha256, ledger_id, name) VALUES (?, ?, 'Atajo de iOS')",
                   Digest::SHA256.hexdigest(token), ledger_id)
      end

      # The clone first, because it is the one that matters. Each move is logged, so a
      # person can put a half-done move back by hand.
      def move(dir)
        FileUtils.mkdir_p(dir)
        rename(legacy_dir, File.join(dir, 'repo'))
        NEXT_TO_THE_LEDGER.each do |name|
          from = File.join(File.dirname(legacy_dir), name)
          rename(from, File.join(dir, name)) if File.exist?(from)
        end
      end

      def rename(from, to)
        File.rename(from, to)
        $stdout.puts "Migración: #{from} → #{to}"
      end

      def title(main) = File.read(main)[/^option "title" "(.+)"/, 1] || 'Ledger'

      def missing_main_file(main)
        found = Dir.glob('*.beancount', base: File.dirname(main))
        "No existe #{main}. Si tu archivo principal tiene otro nombre, pon LEDGER_MAIN_FILE. " \
          "Archivos .beancount en el ledger: #{found.empty? ? 'ninguno' : found.join(', ')}"
      end

      def now = Time.now.utc.iso8601
    end
  end
end
