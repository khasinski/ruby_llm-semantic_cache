# frozen_string_literal: true

require_relative "semantic_cache/version"
require_relative "semantic_cache/configuration"
require_relative "semantic_cache/entry"
require_relative "semantic_cache/embedding"
require_relative "semantic_cache/serializer"
require_relative "semantic_cache/vector_stores/base"
require_relative "semantic_cache/vector_stores/memory"
require_relative "semantic_cache/cache_stores/base"
require_relative "semantic_cache/cache_stores/memory"
require_relative "semantic_cache/middleware"
require_relative "semantic_cache/scoped"

module RubyLLM
  module SemanticCache
    class Error < StandardError; end
    class NotFoundError < Error; end

    class << self
      # Configure the cache
      # @yield [Configuration] the configuration object
      def configure
        yield(config)
        reset! # Reset stores when configuration changes
      end

      # Get the current configuration
      # @return [Configuration]
      def config
        @config ||= Configuration.new
      end

      # Fetch a cached response or execute the block and cache the result
      # @param query [String] the query to cache
      # @param threshold [Float] similarity threshold (overrides config)
      # @param ttl [Integer] time-to-live in seconds (overrides config)
      # @return the cached or computed response
      def fetch(query, threshold: nil, ttl: nil, &block)
        raise ArgumentError, "Block required" unless block_given?

        threshold ||= config.similarity_threshold
        ttl ||= config.ttl_seconds

        # Generate embedding for the query
        embedding = embedding_generator.generate(query)

        # Search for similar cached queries
        matches = vector_store.search(embedding, limit: 1)

        if matches.any? && matches.first[:similarity] >= threshold
          # Cache hit
          record_hit!
          entry_data = cache_store.get(matches.first[:id])

          if entry_data
            return Serializer.deserialize(entry_data[:response])
          end
        end

        # Cache miss - execute block
        record_miss!
        response = block.call

        # Store in cache
        store(query: query, response: response, embedding: embedding, ttl: ttl)

        response
      end

      # Store a response in the cache
      # @param query [String] the query
      # @param response the response to cache
      # @param embedding [Array<Float>] pre-computed embedding (optional)
      # @param metadata [Hash] additional metadata
      # @param ttl [Integer] time-to-live in seconds
      # @return [Entry] the created entry
      def store(query:, response:, embedding: nil, metadata: {}, ttl: nil)
        embedding ||= embedding_generator.generate(query)
        ttl ||= config.ttl_seconds

        entry = Entry.new(
          query: query,
          response: Serializer.serialize(response),
          embedding: embedding,
          metadata: metadata
        )

        vector_store.add(entry.id, embedding)
        cache_store.set(entry.id, entry.to_h, ttl: ttl)

        entry
      end

      # Search for similar cached queries
      # @param query [String] the query to search for
      # @param limit [Integer] maximum number of results
      # @return [Array<Hash>] matching entries with similarity scores
      def search(query, limit: 5)
        embedding = embedding_generator.generate(query)
        matches = vector_store.search(embedding, limit: limit)

        matches.filter_map do |match|
          entry_data = cache_store.get(match[:id])
          next unless entry_data

          {
            query: entry_data[:query],
            response: Serializer.deserialize(entry_data[:response]),
            similarity: match[:similarity],
            metadata: entry_data[:metadata]
          }
        end
      end

      # Check if a similar query exists in the cache
      # @param query [String] the query to check
      # @param threshold [Float] similarity threshold
      # @return [Boolean]
      def exists?(query, threshold: nil)
        threshold ||= config.similarity_threshold
        embedding = embedding_generator.generate(query)
        matches = vector_store.search(embedding, limit: 1)
        matches.any? && matches.first[:similarity] >= threshold
      end

      # Delete a cached entry by query
      # @param query [String] the query to delete
      # @param threshold [Float] similarity threshold for matching
      # @return [Boolean] true if an entry was deleted
      def delete(query, threshold: nil)
        threshold ||= config.similarity_threshold
        embedding = embedding_generator.generate(query)
        matches = vector_store.search(embedding, limit: 1)

        return false unless matches.any? && matches.first[:similarity] >= threshold

        id = matches.first[:id]
        vector_store.delete(id)
        cache_store.delete(id)
        true
      end

      # Clear all cached entries
      def clear!
        vector_store.clear!
        cache_store.clear!
        reset_stats!
      end

      # Invalidate all cache entries similar to the given query
      # @param query [String] the query to match against
      # @param threshold [Float] similarity threshold (defaults to config)
      # @param limit [Integer] maximum entries to invalidate
      # @return [Integer] number of entries invalidated
      def invalidate(query, threshold: nil, limit: 100)
        threshold ||= config.similarity_threshold
        embedding = embedding_generator.generate(query)
        matches = vector_store.search(embedding, limit: limit)

        count = 0
        matches.each do |match|
          next unless match[:similarity] >= threshold

          vector_store.delete(match[:id])
          cache_store.delete(match[:id])
          count += 1
        end

        count
      end

      # Get cache statistics
      # @return [Hash] cache statistics
      def stats
        load_stats!
        {
          hits: @hits,
          misses: @misses,
          hit_rate: hit_rate,
          entries: cache_store.size
        }
      end

      # Reset the cache stores (clears stores but preserves configuration)
      def reset!
        @embedding_generator = nil
        @vector_store = nil
        @cache_store = nil
        @stats_loaded = false
        @hits = 0
        @misses = 0
      end

      # Fully reset including configuration (useful for testing)
      def reset_all!
        @config = nil
        reset!
      end

      # Wrap a RubyLLM::Chat instance with caching middleware
      # @param chat [RubyLLM::Chat] the chat instance to wrap
      # @param threshold [Float, nil] similarity threshold override
      # @param ttl [Integer, nil] TTL override in seconds
      # @param on_cache_hit [Proc, nil] callback for cache hits, receives (chat, user_message, cached_response)
      # @param max_messages [Integer, :unlimited, false, nil] max conversation messages before skipping cache
      #   - Integer: skip cache after N messages (default: 1, only first message cached)
      #   - :unlimited or false: cache all messages regardless of conversation length
      #   - nil: use config default
      # @return [Middleware] the wrapped chat
      def wrap(chat, threshold: nil, ttl: nil, on_cache_hit: nil, max_messages: nil)
        Middleware.new(
          chat,
          threshold: threshold,
          ttl: ttl,
          on_cache_hit: on_cache_hit,
          max_messages: max_messages
        )
      end

      # Access internal components (for middleware)
      # @api private
      def embedding_generator
        @embedding_generator ||= Embedding.new(config)
      end

      # @api private
      def vector_store
        @vector_store ||= build_vector_store
      end

      # @api private
      def cache_store
        @cache_store ||= build_cache_store
      end

      # @api private
      def record_hit!
        load_stats!
        @hits += 1
        persist_stats!
      end

      # @api private
      def record_miss!
        load_stats!
        @misses += 1
        persist_stats!
      end

      private

      def build_vector_store
        case config.vector_store
        when :memory
          VectorStores::Memory.new(config)
        when :redis
          require_relative "semantic_cache/vector_stores/redis"
          VectorStores::Redis.new(config)
        else
          raise Error, "Unknown vector store: #{config.vector_store}"
        end
      end

      def build_cache_store
        case config.cache_store
        when :memory
          CacheStores::Memory.new(config)
        when :redis
          require_relative "semantic_cache/cache_stores/redis"
          CacheStores::Redis.new(config)
        else
          raise Error, "Unknown cache store: #{config.cache_store}"
        end
      end

      def hit_rate
        total = @hits + @misses
        return 0.0 if total.zero?

        @hits.to_f / total
      end

      def reset_stats!
        @hits = 0
        @misses = 0
        @stats_loaded = true
        persist_stats!
      end

      def load_stats!
        return if @stats_loaded

        if config.cache_store == :redis
          stats_data = cache_store.get("__semantic_cache_stats__")
          if stats_data
            @hits = stats_data[:hits] || stats_data["hits"] || 0
            @misses = stats_data[:misses] || stats_data["misses"] || 0
          else
            @hits = 0
            @misses = 0
          end
        else
          @hits ||= 0
          @misses ||= 0
        end
        @stats_loaded = true
      end

      def persist_stats!
        return unless config.cache_store == :redis

        cache_store.set("__semantic_cache_stats__", { hits: @hits, misses: @misses }, ttl: nil)
      end
    end
  end
end
