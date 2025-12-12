# LLMCache

Semantic caching for [Ruby LLM](https://github.com/crmne/ruby_llm) applications. Cache LLM responses based on **semantic similarity**, not exact string matching.

---

## How it works?

Traditional caches require **exact** string matches. Semantic caches understand **meaning**:

```
User asks: "What's the capital of France?"
Cache has: "What is the capital city of France?"

Traditional cache: MISS ❌ (strings don't match)
Semantic cache:    HIT  ✅ (97% similar meaning)
```

The process flow:

```
┌──────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│   User Query     │────▶│    Generate     │────▶│  Vector Search   │
│                  │     │    Embedding    │     │  (find similar)  │
└──────────────────┘     └─────────────────┘     └────────┬─────────┘
                                                          │
                                   ┌──────────────────────┴──────────────────────┐
                                   │                                             │
                                   ▼                                             ▼
                        ┌──────────────────┐                          ┌──────────────────┐
                        │ similarity ≥ 92% │                          │ similarity < 92% │
                        │                  │                          │                  │
                        │  CACHE HIT! ✓    │                          │  CACHE MISS      │
                        │  Return cached   │                          │  Call LLM API    │
                        └──────────────────┘                          └──────────────────┘
```

## Quickstart (30 seconds)

```ruby
# Gemfile
gem 'llm-cache'
gem 'ruby_llm'  # Required dependency
```

```ruby
require 'llm_cache'
require 'ruby_llm'

# That's it! Start caching immediately
response = LLMCache.fetch("What is Ruby?") do
  RubyLLM.chat.ask("What is Ruby?")
end

# This returns the cached response (no API call!)
response = LLMCache.fetch("Tell me about Ruby")  # Similar enough = cache hit
```

**Or wrap your chat for automatic caching:**

```ruby
chat = RubyLLM.chat(model: "gpt-5.2")
cached = LLMCache.wrap(chat)

cached.ask("What is Ruby?")  # Calls API, caches response
cached.ask("What is Ruby?")  # Returns cached response instantly
```

---

## Installation

```ruby
# Gemfile
gem 'llm-cache'

# For Redis backend (optional, recommended for production)
gem 'neighbor-redis'
gem 'redis-client'
```

1. **Query comes in** → "What's France's capital?"
2. **Generate embedding** → Convert to vector (1536 dimensions)
3. **Search cache** → Find vectors with cosine similarity ≥ threshold
4. **Hit or miss** → Return cached response or call LLM and cache result

## Configuration

```ruby
LLMCache.configure do |config|
  # Storage backends: :memory (default) or :redis
  config.vector_store = :redis
  config.cache_store = :redis
  config.redis_url = ENV["REDIS_URL"]

  # Similarity threshold (0.0 to 1.0)
  # Higher = stricter matching, fewer cache hits
  config.similarity_threshold = 0.92

  # Cache TTL (nil = no expiration)
  config.ttl = 24 * 60 * 60  # 24 hours

  # Namespace (for multi-tenant apps)
  config.namespace = "my_app"

  # Embedding model (uses RubyLLM)
  config.embedding_model = "text-embedding-3-small"
  config.embedding_dimensions = 1536

  # Observability (optional)
  config.instrumentation_callback = ->(event, payload) {
    StatsD.timing("llm_cache.#{event}", payload[:duration])
  }
end
```

## Usage

### Basic Fetch

```ruby
response = LLMCache.fetch("What is Ruby?") do
  expensive_llm_call("What is Ruby?")
end
```

### With Options

```ruby
response = LLMCache.fetch(query, threshold: 0.95, ttl: 3600) do
  llm.ask(query)
end
```

### Manual Store & Search

```ruby
# Store directly
LLMCache.store(
  query: "What is Ruby?",
  response: "Ruby is a dynamic programming language...",
  metadata: { model: "gpt-5.2", tokens: 150 }
)

# Search for similar
matches = LLMCache.search("Tell me about Ruby", limit: 5)
# => [{ query: "What is Ruby?", response: "...", similarity: 0.94 }, ...]

# Check existence
LLMCache.exists?("What is Ruby?")  # => true

# Delete
LLMCache.delete("What is Ruby?")

# Invalidate similar entries
LLMCache.invalidate("Ruby programming", threshold: 0.8)
```

### Statistics

```ruby
LLMCache.stats
# => { hits: 150, misses: 20, hit_rate: 0.88, entries: 170 }
```

### Scoped Caches

```ruby
support_cache = LLMCache.new(namespace: "support")
sales_cache = LLMCache.new(namespace: "sales")

support_cache.fetch("How to reset password?") { ... }
sales_cache.fetch("What are pricing plans?") { ... }
```

## RubyLLM Middleware

The cleanest integration - wrap your chat and forget about caching:

```ruby
chat = RubyLLM.chat(model: "gpt-5.2")
cached_chat = LLMCache.wrap(chat)

# Use exactly like a normal chat
response = cached_chat.ask("What is Ruby?")
response = cached_chat.ask("What is Ruby?")  # Instant cache hit
```

### Multi-Turn Conversations

By default, conversation history is included in the cache key:

```ruby
cached_chat = LLMCache.wrap(chat)

# Conversation 1
cached_chat.ask("What is Ruby?")      # Cache miss
cached_chat.ask("Who created it?")    # Cache miss (includes context)

# Conversation 2 (identical flow)
cached_chat2 = LLMCache.wrap(RubyLLM.chat)
cached_chat2.ask("What is Ruby?")     # Cache HIT
cached_chat2.ask("Who created it?")   # Cache HIT (same context)
```

For simple Q&A without context:

```ruby
cached_chat = LLMCache.wrap(chat, include_history: false)
```

### Context-Aware Caching

Different system prompts = different cache keys:

```ruby
formal = LLMCache.wrap(RubyLLM.chat.with_instructions("Be formal"))
casual = LLMCache.wrap(RubyLLM.chat.with_instructions("Be casual"))

formal.ask("Hello")  # Cached separately
casual.ask("Hello")  # Different cache entry
```

### Advanced Options

```ruby
LLMCache.wrap(chat,
  threshold: 0.95,           # Stricter matching
  ttl: 3600,                 # 1 hour TTL
  include_history: true,     # Include conversation context
  hash_history: true,        # Hash context for efficiency
  cache_streaming: true,     # Cache streaming responses
  on_cache_hit: ->(chat, msg, resp) {
    # Custom callback (useful for ActiveRecord persistence)
  }
)
```

### ActiveRecord Persistence

When using `acts_as_chat`, persist cache hits to the database:

```ruby
class Chat < ApplicationRecord
  acts_as_chat

  def cached_ask(message)
    @wrapper ||= LLMCache.wrap(self,
      include_history: false,
      on_cache_hit: method(:persist_cached_response)
    )
    @wrapper.ask(message)
  end

  private

  def persist_cached_response(chat, user_message, cached_response)
    messages.create!(role: :user, content: user_message)
    messages.create!(role: :assistant, content: cached_response.content)
  end
end
```

## Rails Integration

```ruby
# config/initializers/llm_cache.rb
LLMCache.configure do |config|
  config.vector_store = :redis
  config.cache_store = :redis
  config.redis_url = ENV["REDIS_URL"]
  config.similarity_threshold = 0.92
  config.ttl = 7.days.to_i
  config.namespace = Rails.env
end

# app/services/ai_assistant.rb
class AIAssistant
  def answer(question)
    LLMCache.fetch(question) { RubyLLM.chat.ask(question) }
  end
end
```

## Testing

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    LLMCache.reset_all!
    LLMCache.configure do |c|
      c.vector_store = :memory
      c.cache_store = :memory
      c.embedding_dimensions = 1536
    end
  end
end
```

For mocking embeddings in tests, stub `RubyLLM.embed`:

```ruby
allow(RubyLLM).to receive(:embed).and_return(
  double(vectors: Array.new(1536) { rand })
)
```

## Similarity Threshold Guide

| Threshold | Use Case |
|-----------|----------|
| 0.95-1.0 | Strict - Only near-identical queries |
| 0.90-0.94 | **Recommended** - Catches paraphrases |
| 0.85-0.89 | Loose - Higher hits, some risk |
| < 0.85 | Too loose - Likely wrong matches |

## Cost Analysis

Embedding cost is negligible compared to LLM calls:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Cost per Request                            │
├─────────────────────────────────────────────────────────────────┤
│ Embedding (text-embedding-3-small)                              │
│   50 tokens × $0.02/1M = $0.000001                              │
│                                                                 │
│ GPT-5.2 (without cache)                                         │
│   50 input tokens  × $1.75/1M  = $0.0000875                     │
│   200 output tokens × $14.00/1M = $0.0028                       │
│   Total: $0.00289                                               │
│                                                                 │
│ Savings per cache hit: $0.00289 (2,890x embedding cost!)        │
└─────────────────────────────────────────────────────────────────┘
```

**Break-even analysis:**

| Hit Rate | Monthly Queries | Monthly Savings |
|----------|-----------------|-----------------|
| 10% | 100,000 | $28.90 |
| 30% | 100,000 | $86.70 |
| 50% | 100,000 | $144.50 |
| 50% | 1,000,000 | $1,445.00 |

Cache is profitable at **any** hit rate above 0.03%.

## Requirements

- Ruby >= 2.7.0
- [RubyLLM](https://github.com/crmne/ruby_llm) >= 1.0 (for embeddings and chat)
- Redis 8+ (for Redis backend with VectorSet)
- [neighbor-redis](https://github.com/ankane/neighbor-redis) (for Redis backend)

## License

MIT License
