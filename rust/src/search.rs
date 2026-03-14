use crate::suffix_array::SuffixArray;

/// A repeated substring result.
#[derive(Debug)]
pub struct RepeatedSubstring {
    pub substring: String,
    pub length: usize,
    pub count: usize,
}

/// A lightweight candidate: just integers, no string allocation yet.
struct Candidate {
    depth: usize,
    start_rank: usize,
    count: usize,
}

/// Find the top N longest repeated substrings with at least the given
/// minimum length. Substrings containing the sentinel character are
/// filtered out. Results are deduplicated so that substrings contained
/// within a longer result are removed.
///
/// Uses a stack-based O(n) scan of the LCP array to enumerate all LCP
/// intervals (each corresponding to an internal node in the conceptual
/// suffix tree).
pub fn find_top_repeated(top_n: usize, min_len: usize, sa: &SuffixArray) -> Vec<RepeatedSubstring> {
    let n = sa.lcp.len();
    if n == 0 {
        return Vec::new();
    }

    let mut candidates = collect_lcp_intervals(&sa.sa, &sa.lcp, min_len);

    // Sort by depth descending
    candidates.sort_by(|a, b| b.depth.cmp(&a.depth));

    // Pre-dedup at the candidate level using suffix positions (no string
    // allocation). A candidate is dominated if an already-accepted candidate
    // has greater depth, at least as many occurrences, and its text region
    // covers the current candidate's representative suffix position.
    candidates = prededup_candidates(&sa.sa, candidates);

    candidates.truncate(top_n * 4);

    // Materialise
    let mut results: Vec<RepeatedSubstring> = candidates
        .into_iter()
        .map(|c| {
            let start = sa.sa[c.start_rank];
            let substring: String = sa.text[start..start + c.depth].iter().collect();
            RepeatedSubstring {
                length: c.depth,
                count: c.count,
                substring,
            }
        })
        .filter(|rs| !rs.substring.contains('\0'))
        .collect();

    // Sort by length descending
    results.sort_by(|a, b| b.length.cmp(&a.length));

    // Dedup and take top N
    let results = dedup(results);
    results.into_iter().take(top_n).collect()
}

/// Pre-dedup candidates using suffix positions to collapse "towers" of
/// near-identical candidates from the same repeated block.
///
/// A repeated block of length L generates ~L candidates at depths L, L-1, ...
/// all from overlapping text regions. We detect this cheaply: a candidate is
/// dominated if an already-accepted candidate has a greater depth, at least as
/// many occurrences, and its text region covers the current candidate's
/// representative suffix position.
///
/// Input must be sorted by depth descending.
fn prededup_candidates(sa: &[usize], candidates: Vec<Candidate>) -> Vec<Candidate> {
    // Accepted entries: (text_position, depth, count)
    let mut accepted: Vec<(usize, usize, usize)> = Vec::new();
    let mut result = Vec::new();

    for c in candidates {
        let pos = sa[c.start_rank];
        let dominated = accepted.iter().any(|&(a_pos, a_depth, a_count)| {
            // Current candidate's suffix starts inside the accepted candidate's
            // text region, and accepted has >= count.
            pos >= a_pos && pos < a_pos + a_depth && c.count <= a_count
        });
        if !dominated {
            accepted.push((pos, c.depth, c.count));
            result.push(c);
        }
    }
    result
}

/// Stack-based O(n) enumeration of all LCP intervals.
/// Each interval corresponds to an internal node in the conceptual suffix tree
/// with a specific string depth and occurrence count.
fn collect_lcp_intervals(sa: &[usize], lcp: &[usize], min_len: usize) -> Vec<Candidate> {
    let n = sa.len();
    // Stack entries: (depth, left_bound)
    let mut stack: Vec<(usize, usize)> = Vec::new();
    let mut candidates = Vec::new();

    for i in 1..=n {
        let cur_lcp = if i < n { lcp[i] } else { 0 };
        let mut left_bound = i - 1;

        while let Some(&(depth, lb)) = stack.last() {
            if depth <= cur_lcp {
                break;
            }
            stack.pop();
            // The interval [lb, i-1] has all suffixes sharing a prefix of length `depth`.
            // Count of suffixes = i - lb.
            let count = i - lb;
            if depth >= min_len && count >= 2 {
                candidates.push(Candidate {
                    depth,
                    start_rank: lb,
                    count,
                });
            }
            left_bound = lb;
        }

        if cur_lcp > 0 && (stack.is_empty() || stack.last().unwrap().0 < cur_lcp) {
            stack.push((cur_lcp, left_bound));
        }
    }

    candidates
}

/// Remove substrings that are contained within an already-accepted longer
/// result AND have the same or fewer occurrences. A shorter substring with
/// more occurrences is an independent pattern, not a redundant sub-match.
/// Input must be sorted longest-first.
fn dedup(results: Vec<RepeatedSubstring>) -> Vec<RepeatedSubstring> {
    let mut accepted: Vec<RepeatedSubstring> = Vec::new();
    for r in results {
        let dominated = accepted
            .iter()
            .any(|a| a.substring.contains(&r.substring) && r.count <= a.count);
        if !dominated {
            accepted.push(r);
        }
    }
    accepted
}
