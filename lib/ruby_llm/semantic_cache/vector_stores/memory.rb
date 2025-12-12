# frozen_string_literal: true

require_relative "base"

module RubyLLM
  module SemanticCache
    module VectorStores
      class Memory < Base
        def initialize(config)
          super
          @vectors = {}
          @mutex = Mutex.new
        end

        def add(id, embedding)
          @mutex.synchronize do
            @vectors[id] = embedding
          end
        end

        def search(embedding, limit: 5)
          @mutex.synchronize do
            return [] if @vectors.empty?

            results = @vectors.map do |id, stored_embedding|
              similarity = cosine_similarity(embedding, stored_embedding)
              { id: id, similarity: similarity }
            end

            results
              .sort_by { |r| -r[:similarity] }
              .first(limit)
          end
        end

        def delete(id)
          @mutex.synchronize do
            @vectors.delete(id)
          end
        end

        def clear!
          @mutex.synchronize do
            @vectors.clear
          end
        end

        def empty?
          @mutex.synchronize do
            @vectors.empty?
          end
        end

        def size
          @mutex.synchronize do
            @vectors.size
          end
        end

        private

        def cosine_similarity(vec_a, vec_b)
          return 0.0 if vec_a.nil? || vec_b.nil?
          return 0.0 if vec_a.empty? || vec_b.empty?
          return 0.0 if vec_a.length != vec_b.length

          dot_product = 0.0
          norm_a = 0.0
          norm_b = 0.0

          vec_a.each_with_index do |a, i|
            b = vec_b[i]
            dot_product += a * b
            norm_a += a * a
            norm_b += b * b
          end

          return 0.0 if norm_a.zero? || norm_b.zero?

          dot_product / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
        end
      end
    end
  end
end
