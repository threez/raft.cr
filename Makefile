.PHONY: all clean fmt lint docs spec bench bench-mt bench-codec bench-log bench-cluster example

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

bench-codec:
	crystal run bench/codec_bench.cr --release

bench-log:
	crystal run bench/log_bench.cr --release

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
