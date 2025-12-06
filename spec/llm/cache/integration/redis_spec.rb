# frozen_string_literal: true

# Integration tests for Redis backend
# Run with: REDIS_URL=redis://localhost:6379 bundle exec rspec spec/llm/cache/integration/

RSpec.describe "Redis Integration", skip: ENV["REDIS_URL"].nil? do
  # Counter for unique namespaces
  @test_counter = 0

  before(:all) do
    # Verify Redis is available
    require "redis-client"
    client = RedisClient.config(url: ENV["REDIS_URL"]).new_client
    client.call("PING")
  rescue StandardError => e
    skip "Redis not available: #{e.message}"
  end

  before(:each) do
    LLM::Cache.reset_all!

    # Use deterministic embeddings based on text hash
    # This ensures same text always gets same embedding
    @embedding_cache = {}

    # Unique namespace per test using monotonic counter
    self.class.instance_variable_set(:@test_counter, (self.class.instance_variable_get(:@test_counter) || 0) + 1)
    test_num = self.class.instance_variable_get(:@test_counter)

    LLM::Cache.configure do |config|
      config.vector_store = :redis
      config.cache_store = :redis
      config.redis_url = ENV["REDIS_URL"]
      config.namespace = "llm_cache_test_#{Process.pid}_#{test_num}_#{Time.now.to_i}"
      config.embedding_dimensions = 8
      config.similarity_threshold = 0.9
      config.embedding_fn = lambda { |text|
        @embedding_cache[text] ||= begin
          # Deterministic random based on text
          srand(text.hash.abs)
          vec = Array.new(8) { rand }
          mag = Math.sqrt(vec.sum { |x| x * x })
          vec.map { |x| x / mag }
        end
      }
    end
    LLM::Cache.clear!
  end

  after(:each) do
    LLM::Cache.clear! rescue nil
  end

  describe "basic operations" do
    it "stores and retrieves cached responses" do
      # First call - cache miss
      call_count = 0
      result1 = LLM::Cache.fetch("What is Ruby?") do
        call_count += 1
        "Ruby is a programming language"
      end

      expect(result1).to eq("Ruby is a programming language")
      expect(call_count).to eq(1)

      # Second call - cache hit
      result2 = LLM::Cache.fetch("What is Ruby?") do
        call_count += 1
        "This should not be called"
      end

      expect(result2).to eq("Ruby is a programming language")
      expect(call_count).to eq(1)
    end

    it "stores with manual store method" do
      entry = LLM::Cache.store(
        query: "What is Python?",
        response: "Python is a programming language",
        metadata: { model: "test" }
      )

      expect(entry.id).not_to be_nil
      expect(LLM::Cache.exists?("What is Python?")).to be true
    end

    it "searches for similar entries" do
      LLM::Cache.store(query: "What is Ruby?", response: "Ruby response")
      LLM::Cache.store(query: "What is Python?", response: "Python response")

      results = LLM::Cache.search("What is Ruby?", limit: 5)

      expect(results).to be_an(Array)
      expect(results.first[:query]).to eq("What is Ruby?")
    end

    it "deletes entries" do
      LLM::Cache.store(query: "What is Ruby?", response: "Ruby response")
      expect(LLM::Cache.exists?("What is Ruby?")).to be true

      LLM::Cache.delete("What is Ruby?")
      expect(LLM::Cache.exists?("What is Ruby?")).to be false
    end

    it "clears all entries" do
      LLM::Cache.store(query: "Query 1", response: "Response 1")
      LLM::Cache.store(query: "Query 2", response: "Response 2")

      LLM::Cache.clear!

      expect(LLM::Cache.stats[:entries]).to eq(0)
    end

    it "tracks statistics" do
      LLM::Cache.fetch("What is Ruby?") { "Ruby response" }
      LLM::Cache.fetch("What is Ruby?") { "Should not call" }
      LLM::Cache.fetch("What is Python?") { "Python response" }

      stats = LLM::Cache.stats

      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(2)
      expect(stats[:entries]).to eq(2)
    end
  end

  describe "TTL support" do
    it "expires entries after TTL" do
      LLM::Cache.store(
        query: "Temporary query",
        response: "Temporary response",
        ttl: 1
      )

      expect(LLM::Cache.exists?("Temporary query")).to be true

      sleep 1.5

      # Entry should be expired in Redis
      # Note: Vector store entry may still exist, but cache store entry is gone
      results = LLM::Cache.search("Temporary query", limit: 1)
      # The response should be nil because cache entry expired
      expect(results).to be_empty.or(satisfy { |r| r.first[:response].nil? rescue true })
    end
  end

  describe "namespace isolation" do
    it "isolates entries by namespace" do
      embedding_fn = lambda { |text|
        srand(text.hash.abs)
        vec = Array.new(8) { rand }
        mag = Math.sqrt(vec.sum { |x| x * x })
        vec.map { |x| x / mag }
      }

      cache1 = LLM::Cache.new(namespace: "ns1_#{Process.pid}_#{rand(1000000)}")
      cache1.configure do |c|
        c.vector_store = :redis
        c.cache_store = :redis
        c.redis_url = ENV["REDIS_URL"]
        c.embedding_dimensions = 8
        c.embedding_fn = embedding_fn
      end

      cache2 = LLM::Cache.new(namespace: "ns2_#{Process.pid}_#{rand(1000000)}")
      cache2.configure do |c|
        c.vector_store = :redis
        c.cache_store = :redis
        c.redis_url = ENV["REDIS_URL"]
        c.embedding_dimensions = 8
        c.embedding_fn = embedding_fn
      end

      cache1.store(query: "Test query", response: "Response from ns1")
      cache2.store(query: "Test query", response: "Response from ns2")

      results1 = cache1.search("Test query", limit: 1)
      results2 = cache2.search("Test query", limit: 1)

      expect(results1.first[:response]).to eq("Response from ns1")
      expect(results2.first[:response]).to eq("Response from ns2")

      # Cleanup
      cache1.clear!
      cache2.clear!
    end
  end
end
