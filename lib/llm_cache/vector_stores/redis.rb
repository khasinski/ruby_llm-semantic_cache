# frozen_string_literal: true

require_relative "base"

module LLMCache
  module VectorStores
    class Redis < Base
      def initialize(config)
        super
        require_neighbor_redis!
        setup_client
        setup_index
      end

      def add(id, embedding)
        @index.add(id, embedding)
      end

      def search(embedding, limit: 5)
        results = @index.search(embedding, count: limit)

        results.map do |result|
          # VectorSet returns array of hashes: [{id: "...", distance: 0.0}, ...]
          # For cosine distance: similarity = 1 - distance
          id = result[:id]
          distance = result[:distance].to_f
          similarity = 1.0 - distance
          { id: id, similarity: similarity }
        end
      end

      def delete(id)
        @index.remove(id)
      end

      def clear!
        # VectorSet doesn't have a drop method, remove all entries
        # We need to iterate and remove, or delete the key
        @client.call("DEL", index_name)
        setup_index
      end

      def empty?
        size.zero?
      end

      def size
        @index.count
      rescue StandardError
        0
      end

      private

      def require_neighbor_redis!
        require "neighbor-redis"
      rescue LoadError
        raise Error, "neighbor-redis gem is required for Redis vector store. " \
                     "Install it with: gem install neighbor-redis"
      end

      def setup_client
        require "redis-client"

        @client = if @config.redis_client
                    @config.redis_client
                  elsif @config.redis_url
                    RedisClient.config(url: @config.redis_url).new_pool
                  else
                    RedisClient.config.new_pool
                  end

        Neighbor::Redis.client = @client
      end

      def setup_index
        # Use VectorSet for Redis 8+ (works without RediSearch module)
        @index = Neighbor::Redis::VectorSet.new(index_name)
      end

      def index_name
        # VectorSet names cannot contain colons, use underscore
        @config.namespace.gsub(":", "_") + "_vectors"
      end
    end
  end
end
