use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::Path;

/// A suffix tree paired with the original text it was built from.
/// Edge labels are stored as (start, length) indices into the text,
/// so the tree is O(n) in size rather than O(n²).
#[derive(Debug)]
pub struct SuffixTree {
    pub text: Vec<char>,
    pub tree: STree,
}

/// Suffix tree node.
#[derive(Debug, Serialize, Deserialize)]
pub enum STree {
    /// Leaf storing the suffix start index.
    Leaf(usize),
    /// Internal node with edges keyed by first char.
    Internal(BTreeMap<char, SEdge>),
}

/// Edge in the suffix tree. The label is represented as a (start, length)
/// slice into the original text rather than a copied substring.
#[derive(Debug, Serialize, Deserialize)]
pub struct SEdge {
    pub start: usize,
    pub len: usize,
    pub child: STree,
}

/// On-disk cache format: content hash + tree structure only (no text).
/// The text is reconstructed from the original files at load time.
#[derive(Deserialize)]
struct TreeCache {
    content_hash: [u8; 32],
    tree: STree,
}

/// Borrowing version for serialization (avoids cloning the tree to save).
#[derive(Serialize)]
struct TreeCacheRef<'a> {
    content_hash: &'a [u8; 32],
    tree: &'a STree,
}

/// Compute a SHA-256 hash of the concatenated text.
pub fn hash_content(text: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    hasher.finalize().into()
}

/// Try to load a cached tree, validating it against the given text.
/// Returns `None` if the cache doesn't exist, is corrupt, or the hash
/// doesn't match (i.e. source files changed).
pub fn load_cache(path: &Path, combined_text: &str) -> Option<SuffixTree> {
    let data = fs::read(path).ok()?;
    let cache: TreeCache = bincode::deserialize(&data).ok()?;
    let current_hash = hash_content(combined_text);
    if cache.content_hash != current_hash {
        return None;
    }
    let text: Vec<char> = combined_text.chars().collect();
    // The cached tree was built with a trailing '\0' sentinel appended to
    // combined_text, so reconstruct the same text vector.
    let mut text_with_sentinel = text;
    text_with_sentinel.push('\0');
    Some(SuffixTree {
        text: text_with_sentinel,
        tree: cache.tree,
    })
}

/// Save just the tree structure and a content hash to the cache file.
pub fn save_cache_from_tree(path: &Path, content_hash: [u8; 32], tree: &STree) -> io::Result<()> {
    let cache = TreeCacheRef {
        content_hash: &content_hash,
        tree,
    };
    let data =
        bincode::serialize(&cache).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    fs::write(path, data)
}

/// Build a suffix tree from text using naive O(n²) construction.
/// A sentinel character ('\0') is appended to ensure all suffixes are unique.
pub fn build_suffix_tree(txt: &str) -> SuffixTree {
    let mut chars: Vec<char> = txt.chars().collect();
    chars.push('\0');
    let n = chars.len();
    let mut tree = STree::Internal(BTreeMap::new());
    for i in 0..n {
        tree = insert_suffix(&chars, n, i, tree);
    }
    SuffixTree { text: chars, tree }
}

fn insert_suffix(chars: &[char], total_len: usize, suffix_start: usize, tree: STree) -> STree {
    go(
        chars,
        suffix_start,
        total_len - suffix_start,
        suffix_start,
        tree,
    )
}

fn go(chars: &[char], pos: usize, rem_len: usize, suffix_start: usize, tree: STree) -> STree {
    match tree {
        STree::Leaf(i) => STree::Leaf(i),
        STree::Internal(mut edges) => {
            if rem_len == 0 {
                return STree::Internal(edges);
            }

            let c = chars[pos];

            match edges.remove(&c) {
                None => {
                    edges.insert(
                        c,
                        SEdge {
                            start: pos,
                            len: rem_len,
                            child: STree::Leaf(suffix_start),
                        },
                    );
                    STree::Internal(edges)
                }
                Some(SEdge {
                    start: e_start,
                    len: e_len,
                    child,
                }) => {
                    let cp_len = common_prefix_len(chars, pos, rem_len, e_start, e_len);

                    if cp_len == e_len {
                        let child = go(chars, pos + cp_len, rem_len - cp_len, suffix_start, child);
                        edges.insert(
                            c,
                            SEdge {
                                start: e_start,
                                len: e_len,
                                child,
                            },
                        );
                        STree::Internal(edges)
                    } else {
                        let old_start = e_start + cp_len;
                        let old_len = e_len - cp_len;
                        let new_start = pos + cp_len;
                        let new_len = rem_len - cp_len;

                        let old_edge = SEdge {
                            start: old_start,
                            len: old_len,
                            child,
                        };

                        let split_node = if new_len > 0 {
                            let new_leaf = SEdge {
                                start: new_start,
                                len: new_len,
                                child: STree::Leaf(suffix_start),
                            };
                            let mut split_edges = BTreeMap::new();
                            split_edges.insert(chars[old_start], old_edge);
                            split_edges.insert(chars[new_start], new_leaf);
                            STree::Internal(split_edges)
                        } else {
                            let mut split_edges = BTreeMap::new();
                            split_edges.insert(chars[old_start], old_edge);
                            STree::Internal(split_edges)
                        };

                        edges.insert(
                            c,
                            SEdge {
                                start: e_start,
                                len: cp_len,
                                child: split_node,
                            },
                        );
                        STree::Internal(edges)
                    }
                }
            }
        }
    }
}

fn common_prefix_len(chars: &[char], pos1: usize, len1: usize, pos2: usize, len2: usize) -> usize {
    let max_len = len1.min(len2);
    let mut n = 0;
    while n < max_len && chars[pos1 + n] == chars[pos2 + n] {
        n += 1;
    }
    n
}
