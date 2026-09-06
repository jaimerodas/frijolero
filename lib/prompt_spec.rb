# frozen_string_literal: true

require 'json'

module Frijolero
  # Loads an inline OpenAI prompt definition from prompts/<type>/, assembling the request
  # spec from spec.json (model + format metadata), instructions.txt, and schema.json. The
  # schema.json may be either the wrapped block exported from OpenAI ({name, strict, schema})
  # or a bare JSON schema; both are merged into format. Falls back to the `default` folder
  # when the requested type has none.
  class PromptSpec
    def self.load(type, prompts_dir)
      new(type, prompts_dir).load
    end

    def initialize(type, prompts_dir)
      @type = type.to_s
      @prompts_dir = prompts_dir
    end

    def load
      spec = spec_metadata
      spec['instructions'] = read('instructions.txt')
      spec['format'] = merge_schema(spec['format'], read('schema.json'))
      spec
    end

    private

    def dir
      @dir ||= resolve_dir
    end

    def resolve_dir
      candidate = File.join(@prompts_dir, @type)
      return candidate if Dir.exist?(candidate)

      fallback = File.join(@prompts_dir, 'default')
      return fallback if Dir.exist?(fallback)

      raise "No prompt folder for '#{@type}' and no 'default' fallback at #{@prompts_dir}"
    end

    def spec_metadata
      spec = JSON.parse(read('spec.json'))
      missing = %w[model format].reject { |key| spec.key?(key) }
      raise "Prompt spec #{File.join(dir, 'spec.json')} is missing keys: #{missing.join(', ')}" if missing.any?

      spec
    end

    # Wrapped schema.json keys ({name, strict, schema}) override the spec's format metadata;
    # a bare JSON schema is set as format.schema.
    def merge_schema(format, schema_text)
      doc = JSON.parse(schema_text)
      doc.key?('schema') ? format.merge(doc) : format.merge('schema' => doc)
    end

    def read(filename)
      path = File.join(dir, filename)
      raise "Missing prompt file: #{path}" unless File.exist?(path)

      File.read(path)
    end
  end
end
