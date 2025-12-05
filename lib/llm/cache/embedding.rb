# frozen_string_literal: true

module LLM
  module Cache
    class Embedding
      def initialize(config)
        @config = config
      end

      def generate(text)
        if @config.embedding_fn
          @config.embedding_fn.call(text)
        else
          generate_with_ruby_llm(text)
        end
      end

      def generate_batch(texts)
        if @config.embedding_fn
          texts.map { |t| @config.embedding_fn.call(t) }
        else
          generate_batch_with_ruby_llm(texts)
        end
      end

      private

      def generate_with_ruby_llm(text)
        require_ruby_llm!

        result = RubyLLM.embed(
          text,
          model: @config.embedding_model
        )

        # RubyLLM.embed returns vectors as array (single text) or array of arrays (multiple texts)
        vectors = result.vectors
        vectors.is_a?(Array) && vectors.first.is_a?(Array) ? vectors.first : vectors
      end

      def generate_batch_with_ruby_llm(texts)
        require_ruby_llm!

        result = RubyLLM.embed(
          texts,
          model: @config.embedding_model
        )

        result.vectors
      end

      def require_ruby_llm!
        require "ruby_llm"
      rescue LoadError
        raise Error, "ruby_llm gem is required for default embedding generation. " \
                     "Install it with: gem install ruby_llm " \
                     "Or provide a custom embedding_fn in configuration."
      end
    end
  end
end
