# frozen_string_literal: true

RSpec.describe LLMCache do
  before do
    setup_fake_embeddings
  end

  describe "VERSION" do
    it "has a version number" do
      expect(LLMCache::VERSION).not_to be_nil
    end
  end

  describe ".configure" do
    it "allows configuration via block" do
      LLMCache.configure do |config|
        config.similarity_threshold = 0.85
        config.ttl = 3600
        config.namespace = "test_cache"
      end

      expect(LLMCache.config.similarity_threshold).to eq(0.85)
      expect(LLMCache.config.ttl).to eq(3600)
      expect(LLMCache.config.namespace).to eq("test_cache")
    end
  end

  describe ".fetch" do
    it "caches and returns response on first call" do
      call_count = 0

      result = LLMCache.fetch("What is Ruby?") do
        call_count += 1
        "Ruby is a programming language"
      end

      expect(result).to eq("Ruby is a programming language")
      expect(call_count).to eq(1)
    end

    it "returns cached response on subsequent identical calls" do
      call_count = 0

      LLMCache.fetch("What is Ruby?") do
        call_count += 1
        "Ruby is a programming language"
      end

      result = LLMCache.fetch("What is Ruby?") do
        call_count += 1
        "This should not be called"
      end

      expect(result).to eq("Ruby is a programming language")
      expect(call_count).to eq(1)
    end

    it "returns cached response for semantically similar queries" do
      call_count = 0

      LLMCache.configure do |c|
        c.similarity_threshold = 0.5 # Lower threshold for test
      end

      LLMCache.fetch("What is Ruby programming?") do
        call_count += 1
        "Ruby is a dynamic programming language"
      end

      # Similar query
      result = LLMCache.fetch("Tell me about Ruby programming") do
        call_count += 1
        "This should not be called"
      end

      expect(result).to eq("Ruby is a dynamic programming language")
      expect(call_count).to eq(1)
    end

    it "executes block for dissimilar queries" do
      call_count = 0

      LLMCache.fetch("What is Ruby?") do
        call_count += 1
        "Ruby is a programming language"
      end

      # Very different query
      result = LLMCache.fetch("How do I make pizza?") do
        call_count += 1
        "Mix flour and water..."
      end

      expect(result).to eq("Mix flour and water...")
      expect(call_count).to eq(2)
    end

    it "raises ArgumentError without a block" do
      expect { LLMCache.fetch("query") }.to raise_error(ArgumentError, "Block required")
    end

    it "allows overriding threshold per call" do
      LLMCache.fetch("What is Ruby?") do
        "Ruby is a programming language"
      end

      # With very high threshold, similar query won't match
      call_count = 0
      LLMCache.fetch("What is Ruby programming?", threshold: 0.9999) do
        call_count += 1
        "Different response"
      end

      expect(call_count).to eq(1)
    end
  end

  describe ".store" do
    it "stores a response manually" do
      entry = LLMCache.store(
        query: "What is Ruby?",
        response: "Ruby is a programming language"
      )

      expect(entry).to be_a(LLMCache::Entry)
      expect(entry.query).to eq("What is Ruby?")
    end

    it "stores with metadata" do
      entry = LLMCache.store(
        query: "What is Ruby?",
        response: "Ruby is a programming language",
        metadata: { model: "gpt-4", tokens: 100 }
      )

      expect(entry.metadata).to eq({ model: "gpt-4", tokens: 100 })
    end
  end

  describe ".search" do
    before do
      LLMCache.store(query: "What is Ruby?", response: "Ruby is a programming language")
      LLMCache.store(query: "What is Python?", response: "Python is a programming language")
      LLMCache.store(query: "How to make pizza?", response: "Mix flour and water")
    end

    it "returns similar cached entries" do
      results = LLMCache.search("Tell me about Ruby", limit: 5)

      expect(results).to be_an(Array)
      expect(results.first[:query]).to eq("What is Ruby?")
      expect(results.first[:similarity]).to be_a(Float)
    end

    it "respects the limit parameter" do
      results = LLMCache.search("programming", limit: 2)

      expect(results.size).to be <= 2
    end
  end

  describe ".exists?" do
    before do
      LLMCache.store(query: "What is Ruby?", response: "Ruby is a programming language")
    end

    it "returns true for existing similar query" do
      expect(LLMCache.exists?("What is Ruby?")).to be true
    end

    it "returns false for dissimilar query" do
      expect(LLMCache.exists?("How to make pizza?")).to be false
    end
  end

  describe ".delete" do
    before do
      LLMCache.store(query: "What is Ruby?", response: "Ruby is a programming language")
    end

    it "deletes a cached entry" do
      expect(LLMCache.exists?("What is Ruby?")).to be true

      result = LLMCache.delete("What is Ruby?")

      expect(result).to be true
      expect(LLMCache.exists?("What is Ruby?")).to be false
    end

    it "returns false when no matching entry exists" do
      result = LLMCache.delete("Unknown query")

      expect(result).to be false
    end
  end

  describe ".clear!" do
    before do
      LLMCache.store(query: "What is Ruby?", response: "Ruby is a programming language")
      LLMCache.store(query: "What is Python?", response: "Python is a programming language")
    end

    it "clears all cached entries" do
      expect(LLMCache.stats[:entries]).to eq(2)

      LLMCache.clear!

      expect(LLMCache.stats[:entries]).to eq(0)
    end
  end

  describe ".stats" do
    it "tracks hits and misses" do
      setup_fake_embeddings

      LLMCache.fetch("What is Ruby?") { "Ruby response" }
      LLMCache.fetch("What is Ruby?") { "Should not be called" }
      LLMCache.fetch("How to make pizza?") { "Pizza response" }

      stats = LLMCache.stats

      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(2)
      expect(stats[:hit_rate]).to be_within(0.01).of(0.33)
      expect(stats[:entries]).to eq(2)
    end
  end

  describe "Scoped" do
    it "creates isolated cache namespaces" do
      setup_fake_embeddings

      support = LLMCache::Scoped.new(namespace: "support")
      sales = LLMCache::Scoped.new(namespace: "sales")

      support.store(query: "How to reset password?", response: "Support answer")
      sales.store(query: "What is the price?", response: "Sales answer")

      expect(support.stats[:entries]).to eq(1)
      expect(sales.stats[:entries]).to eq(1)
    end
  end
end
