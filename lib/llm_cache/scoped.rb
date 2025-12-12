# frozen_string_literal: true

module LLMCache
  # Scoped cache wrapper for multi-tenant scenarios
  # Each scoped instance maintains its own stores for true isolation
  #
  # @example
  #   support = LLMCache::Scoped.new(namespace: "support")
  #   sales = LLMCache::Scoped.new(namespace: "sales")
  #
  #   support.store(query: "How to reset password?", response: "...")
  #   sales.store(query: "What is the price?", response: "...")
  #
  class Scoped
    attr_reader :namespace

    def initialize(namespace:)
      @namespace = namespace
      @vector_store = nil
      @cache_store = nil
      @hits = 0
      @misses = 0
    end

    def fetch(query, threshold: nil, ttl: nil, &block)
      raise ArgumentError, "Block required" unless block_given?

      threshold ||= config.similarity_threshold
      ttl ||= config.ttl_seconds

      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: 1)

      if matches.any? && matches.first[:similarity] >= threshold
        @hits += 1
        entry_data = cache_store.get(matches.first[:id])
        return Serializer.deserialize(entry_data[:response]) if entry_data
      end

      @misses += 1
      response = block.call

      store(query: query, response: response, embedding: embedding, ttl: ttl)
      response
    end

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

    def exists?(query, threshold: nil)
      threshold ||= config.similarity_threshold
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: 1)
      matches.any? && matches.first[:similarity] >= threshold
    end

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

    def clear!
      vector_store.clear!
      cache_store.clear!
      @hits = 0
      @misses = 0
    end

    def stats
      {
        hits: @hits,
        misses: @misses,
        hit_rate: hit_rate,
        entries: cache_store.size
      }
    end

    def wrap(chat, threshold: nil, ttl: nil, on_cache_hit: nil, max_messages: nil)
      # For scoped wrap, we create a middleware that uses this scoped instance
      ScopedMiddleware.new(
        self,
        chat,
        threshold: threshold,
        ttl: ttl,
        on_cache_hit: on_cache_hit,
        max_messages: max_messages
      )
    end

    private

    def config
      LLMCache.config
    end

    def embedding_generator
      LLMCache.embedding_generator
    end

    def vector_store
      @vector_store ||= build_vector_store
    end

    def cache_store
      @cache_store ||= build_cache_store
    end

    def build_vector_store
      case config.vector_store
      when :memory
        VectorStores::Memory.new(config)
      when :redis
        require_relative "vector_stores/redis"
        VectorStores::Redis.new(scoped_config)
      else
        raise Error, "Unknown vector store: #{config.vector_store}"
      end
    end

    def build_cache_store
      case config.cache_store
      when :memory
        CacheStores::Memory.new(config)
      when :redis
        require_relative "cache_stores/redis"
        CacheStores::Redis.new(scoped_config)
      else
        raise Error, "Unknown cache store: #{config.cache_store}"
      end
    end

    # Create a config-like object with the scoped namespace
    def scoped_config
      ScopedConfig.new(config, @namespace)
    end

    # Wrapper that delegates to main config but overrides namespace
    class ScopedConfig
      def initialize(config, namespace)
        @config = config
        @namespace = namespace
      end

      def namespace
        @namespace
      end

      def method_missing(method, *args, &block)
        @config.send(method, *args, &block)
      end

      def respond_to_missing?(method, include_private = false)
        @config.respond_to?(method, include_private)
      end
    end

    def hit_rate
      total = @hits + @misses
      return 0.0 if total.zero?

      @hits.to_f / total
    end
  end

  # Middleware that uses a scoped cache instance
  class ScopedMiddleware < Middleware
    def initialize(scoped, chat, threshold: nil, ttl: nil, on_cache_hit: nil, max_messages: nil)
      super(chat, threshold: threshold, ttl: ttl, on_cache_hit: on_cache_hit, max_messages: max_messages)
      @scoped = scoped
    end

    private

    def cache_lookup(key)
      embedding = LLMCache.embedding_generator.generate(key)
      threshold = @threshold || LLMCache.config.similarity_threshold

      matches = @scoped.send(:vector_store).search(embedding, limit: 1)

      if matches.any? && matches.first[:similarity] >= threshold
        entry_data = @scoped.send(:cache_store).get(matches.first[:id])
        return nil unless entry_data

        @scoped.instance_variable_set(:@hits, @scoped.instance_variable_get(:@hits) + 1)
        Serializer.deserialize(entry_data[:response])
      end
    end

    def store_in_cache(key, response)
      embedding = LLMCache.embedding_generator.generate(key)
      ttl = @ttl || LLMCache.config.ttl_seconds

      entry = Entry.new(
        query: key,
        response: Serializer.serialize(response),
        embedding: embedding,
        metadata: { model: @chat.model&.id }
      )

      @scoped.send(:vector_store).add(entry.id, embedding)
      @scoped.send(:cache_store).set(entry.id, entry.to_h, ttl: ttl)
      @scoped.instance_variable_set(:@misses, @scoped.instance_variable_get(:@misses) + 1)
    end
  end
end
