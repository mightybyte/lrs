use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io;
use std::path::Path;

/// A suffix array paired with the original text and LCP array.
/// The suffix array is a permutation of [0..n) sorted by suffix order.
/// The LCP array stores the length of the longest common prefix between
/// consecutive suffixes in sorted order.
#[derive(Debug)]
pub struct SuffixArray {
    pub text: Vec<char>,
    pub sa: Vec<usize>,
    pub lcp: Vec<usize>,
}

/// On-disk cache format: content hash + suffix array + LCP array (no text).
#[derive(Deserialize)]
struct SaCache {
    content_hash: [u8; 32],
    sa: Vec<usize>,
    lcp: Vec<usize>,
}

/// Borrowing version for serialization.
#[derive(Serialize)]
struct SaCacheRef<'a> {
    content_hash: &'a [u8; 32],
    sa: &'a [usize],
    lcp: &'a [usize],
}

/// Compute a SHA-256 hash of the concatenated text.
pub fn hash_content(text: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    hasher.finalize().into()
}

/// Try to load a cached suffix array, validating against the given text.
pub fn load_cache(path: &Path, combined_text: &str) -> Option<SuffixArray> {
    let data = fs::read(path).ok()?;
    let cache: SaCache = bincode::deserialize(&data).ok()?;
    let current_hash = hash_content(combined_text);
    if cache.content_hash != current_hash {
        return None;
    }
    let mut text: Vec<char> = combined_text.chars().collect();
    text.push('\0');
    Some(SuffixArray {
        text,
        sa: cache.sa,
        lcp: cache.lcp,
    })
}

/// Save the suffix array and LCP array with a content hash.
pub fn save_cache(path: &Path, content_hash: [u8; 32], sa: &SuffixArray) -> io::Result<()> {
    let cache = SaCacheRef {
        content_hash: &content_hash,
        sa: &sa.sa,
        lcp: &sa.lcp,
    };
    let data =
        bincode::serialize(&cache).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    fs::write(path, data)
}

/// Build a suffix array from text using naive O(n² log n) construction
/// (sort all suffixes), then compute the LCP array in O(n) using Kasai's
/// algorithm.
pub fn build_suffix_array(txt: &str) -> SuffixArray {
    let mut chars: Vec<char> = txt.chars().collect();
    chars.push('\0');
    let n = chars.len();

    // Build suffix array by sorting suffix indices
    let mut sa: Vec<usize> = (0..n).collect();
    sa.sort_by(|&a, &b| {
        let sa_slice = &chars[a..];
        let sb_slice = &chars[b..];
        sa_slice.cmp(sb_slice)
    });

    // Build LCP array using Kasai's algorithm
    let lcp = kasai(&chars, &sa);

    SuffixArray {
        text: chars,
        sa,
        lcp,
    }
}

/// Kasai's algorithm: compute the LCP array in O(n) given text and suffix array.
/// lcp[i] = length of longest common prefix between sa[i-1] and sa[i].
/// lcp[0] = 0 by convention.
fn kasai(text: &[char], sa: &[usize]) -> Vec<usize> {
    let n = sa.len();
    let mut rank = vec![0usize; n];
    for (i, &s) in sa.iter().enumerate() {
        rank[s] = i;
    }

    let mut lcp = vec![0usize; n];
    let mut k: usize = 0;
    for i in 0..n {
        if rank[i] == 0 {
            k = 0;
            continue;
        }
        let j = sa[rank[i] - 1];
        while i + k < n && j + k < n && text[i + k] == text[j + k] {
            k += 1;
        }
        lcp[rank[i]] = k;
        k = k.saturating_sub(1);
    }
    lcp
}
