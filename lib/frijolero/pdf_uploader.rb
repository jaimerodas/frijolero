# frozen_string_literal: true

require 'yaml'

module Frijolero
  # One-time upload of legacy PDFs from ~/Documents/Beancount to B2 with the new naming scheme.
  # Walks <source>/*/pdf/*.pdf, resolves directory and file prefix to account keys,
  # and uploads to accounts/<Key>/<Key> <YYMM>.pdf.
  class PdfUploader
    Result = Struct.new(:uploaded, :skipped, keyword_init: true)

    def initialize(source:, accounts_file:, b2_client:, out: $stdout)
      @source = source
      @b2 = b2_client
      @out = out
      @keys = YAML.load_file(accounts_file).keys
      @normalized_keys = @keys.to_h { |key| [normalize(key), key] }
    end

    # Array of [local_path, b2_key] pairs, sorted. Files that resolve to no key
    # land in `unresolved` so a run never loses a PDF silently.
    def plan
      @unresolved = []
      glob = Dir.glob('*/pdf/*.pdf', base: @source).sort
      glob.map { |path| resolve_pdf(path) }.compact
    end

    def unresolved
      plan if @unresolved.nil?
      @unresolved
    end

    # Execute the plan: upload each PDF, print results, return Result with uploaded and skipped.
    def run
      pairs = plan
      skipped = @unresolved.dup
      skipped.each { |reason| @out.puts "skip #{reason}" }
      uploaded = pairs.filter_map { |local_path, b2_key| upload_one(local_path, b2_key, skipped) }
      Result.new(uploaded: uploaded, skipped: skipped)
    end

    private

    # Returns the key on success; records the failure and returns nil otherwise.
    def upload_one(local_path, b2_key, skipped)
      @b2.put(b2_key, File.join(@source, local_path))
      @out.puts "ok  #{b2_key}"
      b2_key
    rescue B2::Error => e
      skipped << "#{local_path}: #{e.message}"
      @out.puts "skip #{local_path}: #{e.message.lines.first.strip}"
      nil
    end

    def normalize(name)
      name.tr('_', ' ').downcase
    end

    # The directory is the account: the pipeline filed the PDF there. The filename
    # only supplies the period, because legacy prefixes drift (AMEX_Aeromexico/pdf/AMEX_2501.pdf,
    # Openbank/pdf/Open_2507.pdf, BBVA/pdf/BBVA 2605.pdf).
    def resolve_pdf(path)
      dir, _pdf, filename = path.split('/')
      match = filename.match(/[\s_](\d{4})\.pdf\z/i)
      return unresolved!(path, 'name does not end in _YYMM.pdf') unless match

      dir_key = @normalized_keys[normalize(dir)]
      return unresolved!(path, 'directory matches no account key') unless dir_key

      [path, Config.pdf_key(dir_key, match[1])]
    end

    def unresolved!(path, reason)
      @unresolved << "#{path}: #{reason}"
      nil
    end
  end
end
