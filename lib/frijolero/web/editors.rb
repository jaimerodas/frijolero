# frozen_string_literal: true

module Frijolero
  module Web
    # Rules and accounts editors. Reopens App to keep app.rb a table of contents.
    class App
      helpers do
        # Every editor save ends the same way: the ledger repo commits and pushes.
        def commit_config(message)
          self.class.repo.commit_and_push(message)
        end
      end
    end
  end
end
