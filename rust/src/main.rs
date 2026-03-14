use clap::Parser;
use lrs::search::{RepeatedSubstring, find_top_repeated};
use lrs::suffix_array::{build_suffix_array, hash_content, load_cache, save_cache};
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use walkdir::WalkDir;

#[derive(Parser)]
#[command(
    name = "lrs",
    about = "Find the longest repeated substrings in files",
    long_about = "lrs - longest repeated substring finder"
)]
struct Opts {
    /// Number of results to show
    #[arg(short = 'n', long = "top", default_value_t = 10)]
    top_n: usize,

    /// Recursively search directories
    #[arg(short, long)]
    recursive: bool,

    /// Minimum substring length to report
    #[arg(long = "min-length", default_value_t = 2)]
    min_length: usize,

    /// Collapse all whitespace sequences into a single space
    #[arg(long = "collapse-whitespace")]
    collapse_whitespace: bool,

    /// Cache the suffix array to FILE for faster subsequent runs
    #[arg(long)]
    cache: Option<PathBuf>,

    /// One or more input paths
    #[arg(required = true)]
    paths: Vec<PathBuf>,
}

fn main() {
    let opts = Opts::parse();

    let files = resolve_files(opts.recursive, &opts.paths);
    if files.is_empty() {
        eprintln!("Error: no files found");
        process::exit(1);
    }

    let mut combined = read_and_combine(&files);
    if opts.collapse_whitespace {
        combined = collapse_whitespace(&combined);
    }

    let sa = match &opts.cache {
        Some(cache_path) if cache_path.exists() => match load_cache(cache_path, &combined) {
            Some(t) => {
                println!("Loading cached suffix array from {}", cache_path.display());
                t
            }
            None => {
                println!("Cache stale or corrupt, rebuilding...");
                build_and_cache(&combined, Some(cache_path))
            }
        },
        cache_opt => build_and_cache(&combined, cache_opt.as_deref()),
    };

    let mut results = find_top_repeated(opts.top_n, opts.min_length, &sa);
    if opts.collapse_whitespace {
        trim_results(&mut results);
    }

    println!("Analyzed {} file(s)", files.len());
    println!();

    if results.is_empty() {
        println!("No repeated substrings found.");
    } else {
        print_results(&results);
    }
}

fn read_and_combine(files: &[PathBuf]) -> String {
    let mut parts: Vec<String> = Vec::new();
    for f in files {
        match fs::read_to_string(f) {
            Ok(contents) => parts.push(contents),
            Err(e) => {
                eprintln!("Warning: could not read {}: {e}", f.display());
            }
        }
    }
    parts.join("\0") + "\0"
}

fn build_and_cache(combined: &str, cache_path: Option<&Path>) -> lrs::suffix_array::SuffixArray {
    let content_hash = hash_content(combined);
    let sa = build_suffix_array(combined);
    if let Some(path) = cache_path {
        if let Err(e) = save_cache(path, content_hash, &sa) {
            eprintln!("Warning: failed to save cache: {e}");
        } else {
            println!("Saved suffix array cache to {}", path.display());
        }
    }
    sa
}

fn print_results(results: &[RepeatedSubstring]) {
    println!("{:<5}{:<9}{:<9}Substring", "#", "Length", "Count");
    println!("{}", "-".repeat(72));
    for (i, rs) in results.iter().enumerate() {
        println!(
            "{:<5}{:<9}{:<9}{}",
            i + 1,
            rs.length,
            rs.count,
            format_substring(50, &rs.substring)
        );
    }
}

fn format_substring(max_len: usize, s: &str) -> String {
    let escaped: String = s
        .chars()
        .flat_map(|c| match c {
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c => vec![c],
        })
        .collect();

    if escaped.len() > max_len {
        format!("\"{}...\"", &escaped[..max_len])
    } else {
        format!("\"{escaped}\"")
    }
}

fn trim_results(results: &mut Vec<RepeatedSubstring>) {
    for r in results.iter_mut() {
        r.substring = r.substring.trim().to_string();
        r.length = r.substring.len();
    }
    // Trimming may create duplicates; keep the highest-count version of each
    let mut seen = std::collections::HashSet::new();
    results.retain(|r| seen.insert(r.substring.clone()));
}

fn collapse_whitespace(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut in_ws = false;
    for c in s.chars() {
        if c == '\0' {
            // Preserve null sentinels
            in_ws = false;
            result.push(c);
        } else if c.is_whitespace() {
            if !in_ws {
                result.push(' ');
                in_ws = true;
            }
        } else {
            in_ws = false;
            result.push(c);
        }
    }
    result
}

fn resolve_files(recursive: bool, paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for p in paths {
        if p.is_file() {
            files.push(p.clone());
        } else if p.is_dir() {
            if recursive {
                get_files_recursive(p, &mut files);
            } else if let Ok(entries) = fs::read_dir(p) {
                let mut dir_files: Vec<PathBuf> = entries
                    .flatten()
                    .map(|e| e.path())
                    .filter(|p| p.is_file())
                    .collect();
                dir_files.sort();
                files.append(&mut dir_files);
            }
        } else {
            eprintln!(
                "Warning: {} is not a file or directory, skipping",
                p.display()
            );
        }
    }
    files
}

fn get_files_recursive(dir: &Path, files: &mut Vec<PathBuf>) {
    let mut found: Vec<PathBuf> = WalkDir::new(dir)
        .sort_by_file_name()
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .collect();
    found.sort();
    files.append(&mut found);
}
