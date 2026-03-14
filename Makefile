.PHONY: all haskell rust test test-haskell test-rust clean

all: haskell rust

###############

haskell: haskell/result/bin/lrs

rust: rust/target/release/lrs

###############

haskell/result/bin/lrs:
	cd haskell && nix build

rust/target/release/lrs:
	cd rust && cargo build --release

###############

test: test-haskell test-rust

test-haskell: haskell/result/bin/lrs
	./test-suite/run-tests.sh haskell/result/bin/lrs

test-rust: rust/target/release/lrs
	./test-suite/run-tests.sh rust/target/release/lrs

clean:
	rm -rf rust/target haskell/result haskell/dist-newstyle
