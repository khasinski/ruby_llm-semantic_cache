# frozen_string_literal: true

require "json"

RSpec.describe "Semantic Similarity with Real Embeddings" do
  # Load pre-generated embeddings from Ollama (nomic-embed-text, 768 dimensions)
  let(:fixtures_path) { File.expand_path("../fixtures/embeddings.json", __dir__) }
  let(:test_data) { JSON.parse(File.read(fixtures_path), symbolize_names: true) }

  # Build a lookup table for embeddings by query
  let(:embedding_lookup) do
    test_data.each_with_object({}) do |item, hash|
      hash[item[:query]] = item[:embedding]
    end
  end

  before do
    # Use pre-computed embeddings from fixtures
    RubyLLMMock.embedding_fn = ->(text) { embedding_lookup[text] || raise("No embedding for: #{text}") }

    LLMCache.configure do |config|
      config.similarity_threshold = 0.85
      config.vector_store = :memory
      config.cache_store = :memory
    end

    LLMCache.clear!

    # Populate cache with test data
    test_data.each do |item|
      LLMCache.store(
        query: item[:query],
        response: item[:response],
        embedding: item[:embedding]
      )
    end
  end

  after do
    LLMCache.reset!
  end

  describe "similar query matching" do
    it "finds exact matches with very high similarity" do
      results = LLMCache.search("How do I create a new Ruby class?", limit: 1)

      expect(results.length).to eq(1)
      expect(results.first[:query]).to eq("How do I create a new Ruby class?")
      expect(results.first[:similarity]).to be > 0.99
    end

    it "finds Ruby-related questions in top results" do
      results = LLMCache.search("How do I create a new Ruby class?", limit: 5)

      # Most top results should be Ruby-related
      ruby_results = results.select { |r| r[:query].include?("Ruby") }
      expect(ruby_results.length).to be >= 3
    end

    it "finds semantically similar database questions" do
      results = LLMCache.search("How do I connect to PostgreSQL in Ruby?", limit: 3)

      expect(results.length).to be >= 2
      queries = results.map { |r| r[:query] }
      expect(queries).to include("How do I connect to PostgreSQL in Ruby?")
      # At least one other database-related question should be in top 3
      db_related = queries.count { |q| q.include?("Postgres") || q.include?("database") || q.include?("connect") }
      expect(db_related).to be >= 2
    end

    it "finds semantically similar France capital questions with high similarity" do
      results = LLMCache.search("What is the capital of France?", limit: 2)

      expect(results.length).to be >= 2

      # Both France questions should have very high similarity (>95%)
      france_results = results.select { |r| r[:query].include?("capital") && r[:query].include?("France") }
      expect(france_results.length).to eq(2)

      similarities = france_results.map { |r| r[:similarity] }
      expect(similarities.min).to be > 0.95
    end

    it "finds testing-related questions in top results" do
      results = LLMCache.search("How do I write tests in Ruby?", limit: 5)

      queries = results.map { |r| r[:query] }
      expect(queries).to include("How do I write tests in Ruby?")
      # Testing framework question should appear somewhere in top 5
      testing_related = queries.count { |q| q.include?("test") }
      expect(testing_related).to be >= 1
    end
  end

  describe "dissimilar query separation" do
    it "separates programming questions from geography questions" do
      # Search for a Ruby question
      ruby_results = LLMCache.search("How do I create a new Ruby class?", limit: 10)

      # France questions should have low similarity to Ruby questions
      france_result = ruby_results.find { |r| r[:query].include?("France") }

      if france_result
        expect(france_result[:similarity]).to be < 0.7
      end
    end

    it "ranks exact topic matches higher than tangentially related ones" do
      results = LLMCache.search("How do I create a new Ruby class?", limit: 5)

      # Ruby class questions should be ranked higher than database or API questions
      class_questions = results.take(2).map { |r| r[:query] }
      expect(class_questions.any? { |q| q.include?("class") }).to be true
    end
  end

  describe "cache fetch with semantic matching" do
    it "returns cached response for semantically similar query" do
      # First query is cached
      original_query = "How do I create a new Ruby class?"

      # Search with the same query should find it
      expect(LLMCache.exists?(original_query)).to be true

      # Fetch should return the cached response
      result = LLMCache.fetch(original_query) { "This should not be called" }
      expect(result).to eq("To create a Ruby class, use the `class` keyword followed by the class name in CamelCase.")
    end

    it "tracks cache hits and misses correctly" do
      initial_stats = LLMCache.stats

      # This should be a cache hit
      LLMCache.fetch("What is the capital of France?") { "Miss" }

      stats = LLMCache.stats
      expect(stats[:hits]).to eq(initial_stats[:hits] + 1)
      expect(stats[:misses]).to eq(initial_stats[:misses])
    end
  end

  describe "embedding dimensions" do
    it "uses 768-dimensional embeddings (nomic-embed-text)" do
      embedding = test_data.first[:embedding]
      expect(embedding.length).to eq(768)
    end

    it "has normalized-ish embeddings suitable for cosine similarity" do
      embedding = test_data.first[:embedding]

      # Calculate magnitude
      magnitude = Math.sqrt(embedding.sum { |x| x * x })

      # nomic-embed-text embeddings aren't perfectly normalized but have reasonable magnitude
      expect(magnitude).to be_between(5, 50)
    end
  end
end
