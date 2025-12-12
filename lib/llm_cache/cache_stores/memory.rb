# frozen_string_literal: true

require_relative "base"

module LLMCache
  module CacheStores
    class Memory < Base
      CacheEntry = Struct.new(:data, :expires_at, keyword_init: true)

      def initialize(config)
        super
        @store = {}
        @mutex = Mutex.new
      end

      def get(id)
        @mutex.synchronize do
          entry = @store[id]
          return nil unless entry

          if entry.expires_at && Time.now > entry.expires_at
            @store.delete(id)
            return nil
          end

          entry.data
        end
      end

      def set(id, data, ttl: nil)
        @mutex.synchronize do
          expires_at = ttl ? Time.now + ttl : nil
          @store[id] = CacheEntry.new(data: data, expires_at: expires_at)
        end
      end

      def delete(id)
        @mutex.synchronize do
          @store.delete(id)
        end
      end

      def clear!
        @mutex.synchronize do
          @store.clear
        end
      end

      def empty?
        @mutex.synchronize do
          cleanup_expired
          @store.empty?
        end
      end

      def size
        @mutex.synchronize do
          cleanup_expired
          @store.size
        end
      end

      # Iterate over all entries (for invalidation)
      # @yield [id, data] each entry
      def each
        @mutex.synchronize do
          cleanup_expired
          @store.each do |id, entry|
            yield(id, entry.data)
          end
        end
      end

      private

      def cleanup_expired
        now = Time.now
        @store.delete_if do |_id, entry|
          entry.expires_at && now > entry.expires_at
        end
      end
    end
  end
end
