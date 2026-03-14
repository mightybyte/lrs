use crate::suffix_array::SuffixArray;

/// A repeated substring result.
#[derive(Debug)]
pub struct RepeatedSubstring {
    pub substring: String,
    pub length: usize,
    pub count: usize,
    pub position: usize,
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

    // Precompute distance to next sentinel for O(1) sentinel checks.
    // dist_to_sentinel[i] = number of chars from position i until the next '\0'.
    let dist_to_sentinel = {
        let text = &sa.text;
        let mut dist = vec![0usize; text.len()];
        let mut d = 0usize;
        for i in (0..text.len()).rev() {
            if text[i] == '\0' {
                d = 0;
            }
            dist[i] = d;
            d += 1;
        }
        dist
    };

    // Filter out candidates whose representative suffix crosses a sentinel,
    // before sorting/truncation so valid candidates aren't crowded out.
    candidates.retain(|c| {
        let pos = sa.sa[c.start_rank];
        dist_to_sentinel[pos] >= c.depth
    });

    // Sort by depth descending
    candidates.sort_unstable_by(|a, b| b.depth.cmp(&a.depth));

    // Collapse "towers": a repeated block of length L generates candidates
    // at depths L, L-1, L-2, ... all from the same suffix position. Keep
    // only the longest per (position, count) pair so these towers don't
    // crowd out independent shorter patterns.
    candidates = collapse_towers(&sa.sa, candidates);

    // We only need top_n results, so limit candidates before dedup.
    candidates.truncate(top_n * 50);

    // Materialise
    let mut results: Vec<RepeatedSubstring> = candidates
        .into_iter()
        .map(|c| {
            let start = sa.sa[c.start_rank];
            let substring: String = sa.text[start..start + c.depth].iter().collect();
            RepeatedSubstring {
                length: c.depth,
                count: c.count,
                position: start,
                substring,
            }
        })
        .collect();

    // Sort by length descending
    results.sort_by(|a, b| b.length.cmp(&a.length));

    // Dedup and take top N
    let results = dedup(results);
    results.into_iter().take(top_n).collect()
}

/// Collapse towers of candidates from the same repeated block.
/// A block of length L generates candidates at depths L, L-1, ..., where
/// each step shifts the representative suffix position right by 1 while
/// reducing depth by 1, keeping the end position (pos + depth) constant.
/// Keying on (end_position, count) collapses these towers in O(n).
/// Since input is sorted by depth descending, the first candidate seen
/// for each key is the longest.
fn collapse_towers(sa: &[usize], candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut seen = std::collections::HashSet::new();
    candidates
        .into_iter()
        .filter(|c| {
            let pos = sa[c.start_rank];
            seen.insert((pos + c.depth, c.count))
        })
        .collect()
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
