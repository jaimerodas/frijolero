# frozen_string_literal: true

require_relative "lib/frijolero/version"

Gem::Specification.new do |spec|
  spec.name = "frijolero"
  spec.version = Frijolero::VERSION
  spec.authors = ["Jaime Rodas"]
  spec.summary = "Process bank/credit card statements and convert to Beancount format"
  spec.description = "CLI tool for processing PDF bank statements through OpenAI extraction, " \
                     "enriching transactions with custom rules, and converting to Beancount accounting format."
  spec.homepage = "https://github.com/jaimerodas/frijolero"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir.glob("{bin,lib}/**/*") + %w[README.md]
  spec.bindir = "bin"
  spec.executables = ["frijolero"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.add_dependency "csv", "~> 3.0"
end
