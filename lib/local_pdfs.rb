# frozen_string_literal: true

require 'fileutils'
require 'rack/utils'

module Frijolero
  # Where the PDFs go when B2 is not set: the three calls the app makes on B2,
  # over one directory. `presigned_url` is the app's own /pdfs route.
  class LocalPdfs
    def initialize(dir)
      @dir = dir
    end

    def put(key, path)
      dest = File.join(@dir, key)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(path, dest)
    end

    def list(prefix)
      Dir.glob(File.join(@dir, prefix, '*.pdf')).map do |file|
        stat = File.stat(file)
        { key: file.delete_prefix("#{@dir}/"), size: stat.size, last_modified: stat.mtime }
      end
    end

    def presigned_url(key) = "/pdfs/#{Rack::Utils.escape_path(key)}"

    # The file for a key, or nil when it is missing or outside the directory.
    def path(key)
      file = File.expand_path(key, @dir)
      file if file.start_with?("#{@dir}/") && File.file?(file)
    end
  end
end
