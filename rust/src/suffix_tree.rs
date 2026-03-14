use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::Path;

/// A suffix tree paired with the original text it was built from.
/// Edge labels are stored as (start, length) indices into the text,
/// so the tree is O(n) in size rather than O(n²).
#[derive(Debug, Serialize, Deserialize)]
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

/// Load a suffix tree from a binary cache file.
pub fn load_suffix_tree(path: &Path) -> io::Result<SuffixTree> {
    let data = fs::read(path)?;
    bincode::deserialize(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Save a suffix tree to a binary cache file.
pub fn save_suffix_tree(path: &Path, st: &SuffixTree) -> io::Result<()> {
    let data =
        bincode::serialize(st).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
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
    go(chars, suffix_start, total_len - suffix_start, suffix_start, tree)
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

fn common_prefix_len(
    chars: &[char],
    pos1: usize,
    len1: usize,
    pos2: usize,
    len2: usize,
) -> usize {
    let max_len = len1.min(len2);
    let mut n = 0;
    while n < max_len && chars[pos1 + n] == chars[pos2 + n] {
        n += 1;
    }
    n
}
