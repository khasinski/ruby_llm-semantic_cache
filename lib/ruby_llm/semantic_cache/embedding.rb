# frozen_string_literal: true

module RubyLLM
  module SemanticCache
    class Embedding
      def initialize(config)
        @config = config
      end

      def generate(text)
        result = RubyLLM.embed(text, model: @config.embedding_model)

        # RubyLLM.embed returns vectors as array (single text) or array of arrays (multiple texts)
        vectors = result.vectors
        vectors.is_a?(Array) && vectors.first.is_a?(Array) ? vectors.first : vectors
      end

      def generate_batch(texts)
        result = RubyLLM.embed(texts, model: @config.embedding_model)
        result.vectors
      end
    end
  end
end
