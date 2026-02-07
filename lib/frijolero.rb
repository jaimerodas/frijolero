# frozen_string_literal: true

require_relative "frijolero/version"
require_relative "frijolero/ui"
require_relative "frijolero/config"
require_relative "frijolero/account_config"
require_relative "frijolero/accounts"
require_relative "frijolero/detailer"
require_relative "frijolero/openai_client"
require_relative "frijolero/statement_processor"
require_relative "frijolero/beancount_converter"
require_relative "frijolero/beancount_merger"
require_relative "frijolero/csv_converter"
require_relative "frijolero/cli"

module Frijolero
end
