.PHONY: all clean fmt fmtcheck fix lint docs spec bench bench-mt bench-codec bench-log bench-propose bench-cluster example version tag

all: clean fmt lint docs spec

fmt:
	crystal tool format src/ spec/

fmtcheck:
	crystal tool format --check

spec:
	perl -e 'alarm 120; exec @ARGV' crystal spec --verbose

lint: lib/ameba/bin/ameba
	lib/ameba/bin/ameba

fix: lib/ameba/bin/ameba
	lib/ameba/bin/ameba --fix

lib/ameba/bin/ameba:
	shards install
	cd lib/ameba && shards build ameba

docs:
	crystal docs

# Sync the VERSION constant in src/ to match shard.yml's version field.
# Bump shard.yml's version first, then run `make version`.
version:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	for f in $$(grep -rl '^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*"[^"]*"' src/ 2>/dev/null); do \
		sed -E "s/^([[:space:]]*VERSION[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"$$V\"/" "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; \
		echo "updated $$f to $$V"; \
	done

# Create an annotated git tag "vX.Y.Z" from shard.yml's version field.
tag:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	git tag -a "v$$V" -m "Release v$$V"; \
	echo "tagged v$$V"

bench:
	crystal run bench/raft_bench.cr --release

bench-codec:
	crystal run bench/codec_bench.cr --release

bench-log:
	crystal run bench/log_bench.cr --release

bench-propose:
	crystal run bench/propose_bench.cr --release

bench-cluster:
	crystal run bench/cluster_bench.cr --release

bench-mt:
	CRYSTAL_WORKERS=4 crystal run bench/raft_bench.cr --release -Dpreview_mt

example:
	mkdir -p bin
	crystal build examples/kv_store/main.cr -o bin/kv_store
	crystal build examples/kv_store/client.cr -o bin/kv_client

clean:
	rm -rf docs/
