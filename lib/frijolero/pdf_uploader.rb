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

    # Array of [local_path, b2_key] pairs, sorted.
    def plan
      glob = Dir.glob('*/pdf/*.pdf', base: @source).sort
      glob.map { |path| resolve_pdf(path) }.compact
    end

    # Execute the plan: upload each PDF, print results, return Result with uploaded and skipped.
    def run
      uploaded = []
      skipped = []

      plan.each do |local_path, b2_key|
        full_path = File.join(@source, local_path)
        begin
          @b2.put(b2_key, full_path)
          uploaded << b2_key
          @out.puts "ok  #{b2_key}"
        rescue B2::Error => e
          skipped << "#{local_path}: #{e.message}"
        end
      end

      Result.new(uploaded: uploaded, skipped: skipped)
    end

    private

    def normalize(name)
      name.tr('_', ' ').downcase
    end

    def resolve_pdf(path)
      parts = path.split('/')
      return nil unless parts.size == 3 && parts[1] == 'pdf'

      match = parts[2].match(/\A(.+)_(\d{4})\.pdf\z/i)
      return nil unless match

      prefix, yymm = match.captures
      dir_key = @normalized_keys[normalize(parts[0])]
      prefix_key = @normalized_keys[normalize(prefix)]
      return nil unless dir_key && prefix_key && dir_key == prefix_key

      [path, "accounts/#{dir_key}/#{dir_key} #{yymm}.pdf"]
    end
  end
end
