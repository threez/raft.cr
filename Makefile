.PHONY: all clean fmt lint docs spec bench example

all: clean fmt lint docs spec

fmt:
	crystal tool format src/ spec/

spec:
	perl -e 'alarm 120; exec @ARGV' crystal spec --verbose

lint: lib/ameba/bin/ameba
	lib/ameba/bin/ameba

lib/ameba/bin/ameba:
	shards install

docs:
	crystal docs

bench:
	crystal run bench/raft_bench.cr --release

example:
	mkdir -p bin
	crystal build examples/kv_store/main.cr -o bin/kv_store
	crystal build examples/kv_store/client.cr -o bin/kv_client

clean:
	rm -rf docs/
