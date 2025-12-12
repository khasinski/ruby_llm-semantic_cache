# frozen_string_literal: true

module LLMCache
  module CacheStores
    class Base
      def initialize(config)
        @config = config
      end

      # Get a cached entry by ID
      # @param id [String] unique identifier
      # @return [Hash, nil] the cached entry or nil if not found
      def get(id)
        raise NotImplementedError
      end

      # Store an entry
      # @param id [String] unique identifier
      # @param data [Hash] the data to store
      # @param ttl [Integer, nil] time-to-live in seconds
      def set(id, data, ttl: nil)
        raise NotImplementedError
      end

      # Delete an entry by ID
      # @param id [String] unique identifier
      def delete(id)
        raise NotImplementedError
      end

      # Clear all entries
      def clear!
        raise NotImplementedError
      end

      # Check if the store is empty
      def empty?
        raise NotImplementedError
      end

      # Get the number of entries stored
      def size
        raise NotImplementedError
      end
    end
  end
end
