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
      uploaded = []
      pairs = plan
      skipped = @unresolved.dup
      skipped.each { |reason| @out.puts "skip #{reason}" }

      pairs.each do |local_path, b2_key|
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
      dir, _pdf, filename = path.split('/')
      match = filename.match(/\A(.+)_(\d{4})\.pdf\z/i)
      return unresolved!(path, 'name is not Prefix_YYMM.pdf') unless match

      prefix, yymm = match.captures
      dir_key = @normalized_keys[normalize(dir)]
      prefix_key = @normalized_keys[normalize(prefix)]
      return unresolved!(path, 'directory matches no account key') unless dir_key
      return unresolved!(path, 'prefix does not match the directory account') unless prefix_key == dir_key

      [path, "accounts/#{dir_key}/#{dir_key} #{yymm}.pdf"]
    end

    def unresolved!(path, reason)
      @unresolved << "#{path}: #{reason}"
      nil
    end
  end
end
