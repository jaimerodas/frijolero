# frozen_string_literal: true

require_relative 'lib/frijolero/version'

Gem::Specification.new do |spec|
  spec.name = 'frijolero'
  spec.version = Frijolero::VERSION
  spec.authors = ['Jaime Rodas']
  spec.summary = 'Process bank/credit card statements and convert to Beancount format'
  spec.description = 'Web app that processes PDF bank statements through OpenAI ' \
                     'extraction, enriches transactions with custom rules, and ' \
                     'converts them to Beancount accounting format.'
  spec.homepage = 'https://github.com/jaimerodas/frijolero'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.files = Dir.glob('lib/**/*') + %w[README.md]
  spec.require_paths = ['lib']

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.add_dependency 'bigdecimal', '~> 3.1'
  spec.add_dependency 'cli-ui'
  spec.add_dependency 'puma', '~> 8.0'
  spec.add_dependency 'sinatra', '~> 4.0'
end
