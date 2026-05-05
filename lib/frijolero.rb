# frozen_string_literal: true

require_relative 'frijolero/version'
require_relative 'frijolero/ui'
require_relative 'frijolero/config'
require_relative 'frijolero/account_config'
require_relative 'frijolero/accounts'
require_relative 'frijolero/detailer'
require_relative 'frijolero/openai_client'
require_relative 'frijolero/openai_error_reporter'
require_relative 'frijolero/converters/account_targets'
require_relative 'frijolero/converters/base'
require_relative 'frijolero/converters/beancount'
require_relative 'frijolero/converters/cetes_directo'
require_relative 'frijolero/converters/fintual'
require_relative 'frijolero/pipeline'
require_relative 'frijolero/beancount_merger'
require_relative 'frijolero/csv_converter'
require_relative 'frijolero/account_renamer'
require_relative 'frijolero/beancount/parser'
require_relative 'frijolero/beancount/main_file_writer'
require_relative 'frijolero/transaction_splitter'
require_relative 'frijolero/statement'
require_relative 'frijolero/statement_processor'
require_relative 'frijolero/cli'

module Frijolero
end
