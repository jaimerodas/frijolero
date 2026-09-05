# frozen_string_literal: true

module Frijolero
  module Web
    # Statement page and its actions. Reopens App to keep app.rb a table of contents.
    class App
      helpers do
        # The two files a processed statement leaves in the ledger.
        def statement_paths(account, period)
          { json: Config.statement_path(account, period, 'json'),
            beancount: Config.statement_path(account, period, 'beancount') }
        end
      end
    end
  end
end
