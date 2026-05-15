# frozen_string_literal: true

module Frijolero
  class LayoutMigrator
    module FileCompare
      module_function

      def bytes_equal?(path_a, path_b)
        File.size(path_a) == File.size(path_b) &&
          File.read(path_a, mode: 'rb') == File.read(path_b, mode: 'rb')
      end
    end
  end
end
