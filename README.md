# lrs - Longest Repeated Substring Finder

Find the longest repeated substrings in files using suffix arrays.

`lrs` scans text files, builds a suffix array with LCP (Longest Common Prefix) array using Kasai's algorithm, and reports the top N longest substrings that appear more than once. It works across multiple files and can recursively search directories, making it useful for detecting duplicated code, repeated content, or copy-paste patterns in a codebase.

## Example

```
$ lrs src/ -r -n 5
Analyzed 12 file(s)

#    Length   Count    Substring
------------------------------------------------------------------------
1    156      3        "    let results = findTopRepeated (_opts_topN opt..."
2    89       2        "import qualified Data.Text as T\nimport qualified..."
3    67       4        "          acc' = if depth >= minLen && count >= 2..."
4    52       2        "alpha: the quick brown fox jumped over the lazy d..."
5    31       5        "epsilon: hello world from the..."
```

## Installation

The project has two independent implementations with identical behavior and CLI interfaces:

### Rust

```
cd rust
cargo build --release
# Binary at rust/target/release/lrs
```

### Haskell

Requires [Nix](https://nixos.org/) with flakes enabled:

```
cd haskell
nix build
# Binary at haskell/result/bin/lrs
```

### Both

```
make all
```

## Usage

```
lrs [OPTIONS] <PATHS>...
```

### Arguments

| Argument | Description |
|----------|-------------|
| `PATHS...` | One or more files or directories to analyze |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `-n, --top N` | 10 | Number of results to show |
| `-r, --recursive` | off | Recursively search directories |
| `--min-length N` | 2 | Minimum substring length to report |
| `--cache FILE` | none | Cache the suffix array to FILE for faster subsequent runs |

### Examples

Scan a single file:

```
lrs myfile.txt
```

Recursively scan a source directory, showing top 20 results:

```
lrs src/ -r -n 20
```

Only show repeated substrings of 50+ characters:

```
lrs src/ -r --min-length 50
```

Cache the suffix array for faster re-runs:

```
lrs src/ -r --cache .lrs-cache
```

The cache stores a SHA-256 hash of the input content and automatically rebuilds if any files change.

## How It Works

1. **Read and concatenate** all input files, separated by null bytes (which act as sentinels to prevent false cross-file matches).
2. **Build a suffix array** by sorting all suffix indices, then compute the LCP array in O(n) using Kasai's algorithm.
3. **Enumerate LCP intervals** using a stack-based O(n) scan. Each interval corresponds to a distinct repeated substring with a specific length and occurrence count.
4. **Dedup results** using a two-level strategy: first a cheap candidate-level pass using suffix positions to collapse near-identical candidates from the same repeated region, then a final string-level pass to remove substrings contained within longer results.

## Testing

Run the language-agnostic test suite against both implementations:

```
make test
```

Or test individually:

```
make test-rust
make test-haskell
```

Each implementation also has its own unit tests:

```
cd rust && cargo test
cd haskell && nix develop -c cabal test
```

## License

BSD-3-Clause
