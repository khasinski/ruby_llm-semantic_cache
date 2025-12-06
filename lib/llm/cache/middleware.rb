# frozen_string_literal: true

module LLM
  module Cache
    # Middleware wrapper for RubyLLM::Chat that automatically caches responses
    #
    # @example Basic usage
    #   chat = RubyLLM.chat(model: "gpt-4o")
    #   cached_chat = LLM::Cache.wrap(chat)
    #   cached_chat.ask("What is 2+2?")  # First call - executes LLM
    #   cached_chat.ask("What is 2+2?")  # Second call - returns cached response
    #
    # @example With custom threshold
    #   cached_chat = LLM::Cache.wrap(chat, threshold: 0.95)
    #
    class Middleware
      # Methods to delegate directly to the wrapped chat (no caching)
      DELEGATED_METHODS = %i[
        model messages tools params headers schema
        with_instructions with_tool with_tools with_model
        with_temperature with_context with_params with_headers with_schema
        on_new_message on_end_message on_tool_call on_tool_result
        each reset_messages!
      ].freeze

      attr_reader :chat, :cache_instance

      # @param chat [RubyLLM::Chat] the chat instance to wrap
      # @param cache [LLM::Cache::Instance, nil] optional cache instance
      # @param threshold [Float, nil] similarity threshold override
      # @param ttl [Integer, nil] TTL override in seconds
      def initialize(chat, cache: nil, threshold: nil, ttl: nil)
        @chat = chat
        @cache_instance = cache
        @threshold = threshold
        @ttl = ttl
      end

      # Ask a question with automatic caching
      # @param message [String] the message to send
      # @param with [Object] attachments to include
      # @return [RubyLLM::Message] the response message
      def ask(message = nil, with: nil, &block)
        # Skip caching for streaming requests
        return @chat.ask(message, with: with, &block) if block_given?

        # Skip caching if message has attachments
        return @chat.ask(message, with: with) if with

        # Skip caching for tool-enabled chats (responses may vary)
        return @chat.ask(message, with: with) if @chat.tools.any?

        # Use cache
        cache_key = build_cache_key(message)

        cached = cache_lookup(cache_key)
        return cached if cached

        # Execute the actual LLM call
        response = @chat.ask(message)

        # Cache the response
        store_in_cache(cache_key, response)

        response
      end

      alias say ask

      # Delegate other methods to the wrapped chat
      DELEGATED_METHODS.each do |method|
        define_method(method) do |*args, **kwargs, &block|
          result = @chat.send(method, *args, **kwargs, &block)
          # If the method returns the chat (for chaining), return self instead
          result.equal?(@chat) ? self : result
        end
      end

      private

      def build_cache_key(message)
        # Include system instructions in the cache key for context-aware caching
        system_messages = @chat.messages.select { |m| m.role == :system }
        system_context = system_messages.map { |m| extract_text(m.content) }.join("\n")

        if system_context.empty?
          message.to_s
        else
          "#{system_context}\n---\n#{message}"
        end
      end

      def extract_text(content)
        case content
        when String
          content
        when ->(c) { c.respond_to?(:text) }
          content.text
        else
          content.to_s
        end
      end

      def cache_lookup(key)
        embedding = embedding_generator.generate(key)
        threshold = @threshold || config.similarity_threshold

        matches = vector_store.search(embedding, limit: 1)

        return nil unless matches.any? && matches.first[:similarity] >= threshold

        entry_data = cache_store_instance.get(matches.first[:id])
        return nil unless entry_data

        record_hit!
        deserialize_message(entry_data[:response])
      end

      def store_in_cache(key, response)
        record_miss!
        embedding = embedding_generator.generate(key)
        ttl = @ttl || config.ttl_seconds

        entry = Entry.new(
          query: key,
          response: serialize_message(response),
          embedding: embedding,
          metadata: { model: @chat.model&.id }
        )

        vector_store.add(entry.id, embedding)
        cache_store_instance.set(entry.id, entry.to_h, ttl: ttl)
      end

      def serialize_message(message)
        return LLM::Cache.send(:serialize_response, message) unless defined?(RubyLLM::Message)
        return LLM::Cache.send(:serialize_response, message) unless message.is_a?(RubyLLM::Message)

        {
          type: "rubyllm_message",
          value: {
            role: message.role,
            content: serialize_content(message.content),
            model_id: message.model_id,
            tool_calls: message.tool_calls,
            tool_call_id: message.tool_call_id,
            input_tokens: message.input_tokens,
            output_tokens: message.output_tokens,
            cached_tokens: message.cached_tokens,
            cache_creation_tokens: message.cache_creation_tokens
          }.compact
        }
      end

      def serialize_content(content)
        case content
        when String
          { type: "string", value: content }
        when Hash
          { type: "hash", value: content }
        when ->(c) { defined?(RubyLLM::Content) && c.is_a?(RubyLLM::Content) }
          { type: "rubyllm_content", value: content.to_h }
        else
          { type: "string", value: content.to_s }
        end
      end

      def deserialize_message(data)
        return data unless data.is_a?(Hash)

        type = data[:type] || data["type"]
        value = data[:value] || data["value"]

        case type
        when "rubyllm_message"
          return value unless defined?(RubyLLM::Message)

          # Reconstruct the RubyLLM::Message
          content = deserialize_content(value[:content] || value["content"])
          RubyLLM::Message.new(
            role: (value[:role] || value["role"]).to_sym,
            content: content,
            model_id: value[:model_id] || value["model_id"],
            tool_calls: value[:tool_calls] || value["tool_calls"],
            tool_call_id: value[:tool_call_id] || value["tool_call_id"],
            input_tokens: value[:input_tokens] || value["input_tokens"],
            output_tokens: value[:output_tokens] || value["output_tokens"],
            cached_tokens: value[:cached_tokens] || value["cached_tokens"],
            cache_creation_tokens: value[:cache_creation_tokens] || value["cache_creation_tokens"]
          )
        else
          LLM::Cache.send(:deserialize_response, data)
        end
      end

      def deserialize_content(data)
        return data unless data.is_a?(Hash)

        type = data[:type] || data["type"]
        value = data[:value] || data["value"]

        case type
        when "string", "hash"
          value
        when "rubyllm_content"
          # Return as hash - RubyLLM::Message will handle it
          value
        else
          value
        end
      end

      def config
        @cache_instance ? @cache_instance.instance_variable_get(:@config) : LLM::Cache.config
      end

      def embedding_generator
        @embedding_generator ||= Embedding.new(config)
      end

      def vector_store
        if @cache_instance
          @cache_instance.send(:vector_store)
        else
          LLM::Cache.send(:vector_store)
        end
      end

      def cache_store_instance
        if @cache_instance
          @cache_instance.send(:cache_store)
        else
          LLM::Cache.send(:cache_store)
        end
      end

      def record_hit!
        if @cache_instance
          @cache_instance.instance_variable_set(:@hits, @cache_instance.instance_variable_get(:@hits) + 1)
        else
          LLM::Cache.send(:record_hit!)
        end
      end

      def record_miss!
        if @cache_instance
          @cache_instance.instance_variable_set(:@misses, @cache_instance.instance_variable_get(:@misses) + 1)
        else
          LLM::Cache.send(:record_miss!)
        end
      end
    end
  end
end
