# frozen_string_literal: true

require_relative "base"

module LLM
  module Cache
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

          results.map do |id, distance|
            # neighbor-redis returns distance, convert to similarity
            # For cosine distance: similarity = 1 - distance
            similarity = 1.0 - distance.to_f
            { id: id, similarity: similarity }
          end
        end

        def delete(id)
          @index.remove(id)
        end

        def clear!
          @index.drop if @index.exists?
          setup_index
        end

        def empty?
          size.zero?
        end

        def size
          return 0 unless @index.exists?

          @index.info[:num_docs] || 0
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
          Neighbor::Redis.client = if @config.redis_client
                                     @config.redis_client
                                   elsif @config.redis_url
                                     require "redis-client"
                                     RedisClient.config(url: @config.redis_url).new_pool
                                   else
                                     require "redis-client"
                                     RedisClient.config.new_pool
                                   end
        end

        def setup_index
          index_name = "#{@config.namespace}:vectors"

          @index = Neighbor::Redis::HnswIndex.new(
            index_name,
            dimensions: @config.embedding_dimensions,
            distance_metric: :cosine
          )

          @index.create unless @index.exists?
        end
      end
    end
  end
end
