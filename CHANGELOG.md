# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-12-12

### Added

- Initial release of RubyLLM::SemanticCache
- Semantic caching based on embedding similarity (not exact string matching)
- Configurable similarity threshold (default: 0.92)
- Support for memory and Redis vector/cache stores
- `RubyLLM::SemanticCache.wrap(chat)` to wrap RubyLLM::Chat instances
- `RubyLLM::SemanticCache.fetch(query) { ... }` for one-off caching
- Multi-turn conversation caching with `max_messages` option
- Scoped caches for multi-tenant isolation (`RubyLLM::SemanticCache::Scoped`)
- Cache statistics (hits, misses, hit rate)
- TTL support for cache expiration
- Proper serialization/deserialization of RubyLLM::Message objects
