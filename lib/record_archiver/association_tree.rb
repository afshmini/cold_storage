# frozen_string_literal: true

module RecordArchiver
  # Normalizes the association trees used by `cascade:` and `with:` into a
  # plain Hash of name => nested tree.
  #
  #   :lines                          => { lines: nil }
  #   [:lines, :notes]                => { lines: nil, notes: nil }
  #   [{ lines: [:taxes] }, :notes]   => { lines: [:taxes], notes: nil }
  #
  # Nested values are left as given; each level normalizes its own.
  module AssociationTree
    module_function

    def normalize(value)
      case value
      when nil, false     then {}
      when Symbol, String then { value.to_sym => nil }
      when Array          then value.inject({}) { |tree, item| tree.merge(normalize(item)) }
      when Hash           then value.to_h { |name, nested| [name.to_sym, nested] }
      else
        raise ArgumentError, "expected an association name, array or hash, got #{value.inspect}"
      end
    end
  end
end
