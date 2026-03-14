use crate::suffix_tree::{SEdge, STree, SuffixTree};

/// A repeated substring result.
#[derive(Debug)]
pub struct RepeatedSubstring {
    pub substring: String,
    pub length: usize,
    pub count: usize,
}

/// A candidate from tree traversal. Stores only cheap integer metadata;
/// the actual substring is materialised later for just the final winners.
struct Candidate {
    depth: usize,
    leaf_idx: usize,
    count: usize,
}

/// Find the top N longest repeated substrings with at least the given
/// minimum length. Substrings containing the sentinel character are
/// filtered out. Results are deduplicated so that substrings contained
/// within a longer result are removed.
pub fn find_top_repeated(top_n: usize, min_len: usize, st: &SuffixTree) -> Vec<RepeatedSubstring> {
    let (_, _, mut candidates) = analyze(min_len, 0, &st.tree);

    // Sort by depth descending
    candidates.sort_by(|a, b| b.depth.cmp(&a.depth));
    candidates.truncate(top_n * 4);

    // Materialise candidates
    let mut results: Vec<RepeatedSubstring> = candidates
        .into_iter()
        .map(|c| materialise(&st.text, c))
        .filter(|rs| !rs.substring.contains('\0'))
        .collect();

    // Sort by length descending
    results.sort_by(|a, b| b.length.cmp(&a.length));

    // Dedup
    let results = dedup(results);

    results.into_iter().take(top_n).collect()
}

fn materialise(text: &[char], c: Candidate) -> RepeatedSubstring {
    let substring: String = text[c.leaf_idx..c.leaf_idx + c.depth].iter().collect();
    RepeatedSubstring {
        length: c.depth,
        count: c.count,
        substring,
    }
}

/// Remove substrings that are contained within an already-accepted longer
/// result. Input must be sorted longest-first.
fn dedup(results: Vec<RepeatedSubstring>) -> Vec<RepeatedSubstring> {
    let mut accepted: Vec<RepeatedSubstring> = Vec::new();
    for r in results {
        let dominated = accepted.iter().any(|a| a.substring.contains(&r.substring));
        if !dominated {
            accepted.push(r);
        }
    }
    accepted
}

/// Single-pass traversal returning (leaf count, representative leaf index, candidates).
/// Only emits a candidate when depth >= min_len.
fn analyze(min_len: usize, depth: usize, tree: &STree) -> (usize, usize, Vec<Candidate>) {
    match tree {
        STree::Leaf(i) => (1, *i, Vec::new()),
        STree::Internal(edges) => {
            let mut total_leaves = 0;
            let mut any_leaf = 0;
            let mut all_candidates = Vec::new();
            let mut first = true;

            for SEdge { len, child, .. } in edges.values() {
                let (leaves, leaf_idx, mut cands) = analyze(min_len, depth + len, child);
                total_leaves += leaves;
                if first {
                    any_leaf = leaf_idx;
                    first = false;
                }
                all_candidates.append(&mut cands);
            }

            if depth >= min_len {
                all_candidates.push(Candidate {
                    depth,
                    leaf_idx: any_leaf,
                    count: total_leaves,
                });
            }

            (total_leaves, any_leaf, all_candidates)
        }
    }
}
