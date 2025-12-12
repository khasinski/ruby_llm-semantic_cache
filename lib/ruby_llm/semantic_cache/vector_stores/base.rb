# frozen_string_literal: true

module RubyLLM
  module SemanticCache
    module VectorStores
      class Base
        def initialize(config)
          @config = config
        end

        # Add a vector with the given ID
        # @param id [String] unique identifier
        # @param embedding [Array<Float>] vector embedding
        def add(id, embedding)
          raise NotImplementedError
        end

        # Search for similar vectors
        # @param embedding [Array<Float>] query vector
        # @param limit [Integer] maximum number of results
        # @return [Array<Hash>] array of { id:, similarity: } hashes
        def search(embedding, limit: 5)
          raise NotImplementedError
        end

        # Delete a vector by ID
        # @param id [String] unique identifier
        def delete(id)
          raise NotImplementedError
        end

        # Clear all vectors
        def clear!
          raise NotImplementedError
        end

        # Check if the store is empty
        def empty?
          raise NotImplementedError
        end

        # Get the number of vectors stored
        def size
          raise NotImplementedError
        end
      end
    end
  end
end
