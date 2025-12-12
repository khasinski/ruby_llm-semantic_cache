# frozen_string_literal: true

require "digest"

module LLMCache
  class Embedding
    def initialize(config)
      @config = config
      @cache = {}
      @cache_mutex = Mutex.new
    end

    def generate(text)
      return generate_uncached(text) unless @config.cache_embeddings

      cache_key = embedding_cache_key(text)

      @cache_mutex.synchronize do
        return @cache[cache_key] if @cache.key?(cache_key)
      end

      embedding = instrument(:embedding_generate, text: text, cached: false) do
        generate_uncached(text)
      end

      @cache_mutex.synchronize do
        @cache[cache_key] = embedding
      end

      embedding
    end

    def generate_batch(texts)
      if @config.cache_embeddings
        # Check cache for each text, generate missing ones
        results = []
        uncached_texts = []
        uncached_indices = []

        texts.each_with_index do |text, idx|
          cache_key = embedding_cache_key(text)
          cached = @cache_mutex.synchronize { @cache[cache_key] }

          if cached
            results[idx] = cached
          else
            uncached_texts << text
            uncached_indices << idx
          end
        end

        # Generate uncached embeddings
        if uncached_texts.any?
          new_embeddings = instrument(:embedding_generate_batch, count: uncached_texts.size) do
            generate_batch_uncached(uncached_texts)
          end

          uncached_texts.each_with_index do |text, i|
            idx = uncached_indices[i]
            embedding = new_embeddings[i]
            results[idx] = embedding

            cache_key = embedding_cache_key(text)
            @cache_mutex.synchronize { @cache[cache_key] = embedding }
          end
        end

        results
      else
        generate_batch_uncached(texts)
      end
    end

    # Clear the embedding cache
    def clear_cache!
      @cache_mutex.synchronize { @cache.clear }
    end

    # Get cache statistics
    def cache_stats
      @cache_mutex.synchronize do
        { size: @cache.size }
      end
    end

    private

    def embedding_cache_key(text)
      Digest::SHA256.hexdigest(text)
    end

    def generate_uncached(text)
      result = RubyLLM.embed(text, model: @config.embedding_model)

      # RubyLLM.embed returns vectors as array (single text) or array of arrays (multiple texts)
      vectors = result.vectors
      vectors.is_a?(Array) && vectors.first.is_a?(Array) ? vectors.first : vectors
    end

    def generate_batch_uncached(texts)
      result = RubyLLM.embed(texts, model: @config.embedding_model)
      result.vectors
    end

    def instrument(event_name, payload = {})
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = yield

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      payload[:duration] = duration

      notify(event_name, payload)

      result
    end

    def notify(event_name, payload)
      # Custom callback
      @config.instrumentation_callback&.call(event_name, payload)

      # ActiveSupport::Notifications integration
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument("#{event_name}.llm_cache", payload)
      end
    end
  end
end
