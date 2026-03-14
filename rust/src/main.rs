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

    let raw_combined = read_and_combine(&files);
    let file_index = build_file_index(&files, &raw_combined);

    let (combined, pos_map) = if opts.collapse_whitespace {
        let (collapsed, map) = collapse_whitespace(&raw_combined);
        (collapsed, Some(map))
    } else {
        (raw_combined, None)
    };

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

    // Map positions back to original text when whitespace was collapsed
    if let Some(ref map) = pos_map {
        for r in results.iter_mut() {
            if r.position < map.len() {
                r.position = map[r.position];
            }
        }
    }

    println!("Analyzed {} file(s)", files.len());
    println!();

    if results.is_empty() {
        println!("No repeated substrings found.");
    } else {
        print_results(&results, &file_index);
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

/// An entry in the file index mapping character offsets to file/line info.
struct FileEntry {
    start: usize,
    path: PathBuf,
    line_offsets: Vec<usize>,
}

/// Build an index mapping character positions in the combined text back to
/// file paths and line numbers.
fn build_file_index(files: &[PathBuf], combined: &str) -> Vec<FileEntry> {
    let mut entries = Vec::new();
    let mut offset = 0;
    for file_text in combined.split('\0') {
        if file_text.is_empty() {
            offset += 1; // skip the \0
            continue;
        }
        if let Some(path) = files.get(entries.len()) {
            let mut line_offsets = vec![0usize];
            for (i, c) in file_text.chars().enumerate() {
                if c == '\n' {
                    line_offsets.push(i + 1);
                }
            }
            entries.push(FileEntry {
                start: offset,
                path: path.clone(),
                line_offsets,
            });
        }
        offset += file_text.chars().count() + 1; // +1 for the \0
    }
    entries
}

/// Look up the file path and line number for a character position.
fn lookup_location(file_index: &[FileEntry], pos: usize) -> (String, usize) {
    for entry in file_index.iter().rev() {
        if pos >= entry.start {
            let local_pos = pos - entry.start;
            let line = match entry.line_offsets.binary_search(&local_pos) {
                Ok(i) => i + 1,
                Err(i) => i,
            };
            return (entry.path.display().to_string(), line);
        }
    }
    ("<unknown>".to_string(), 0)
}

fn print_results(results: &[RepeatedSubstring], file_index: &[FileEntry]) {
    let locations: Vec<String> = results
        .iter()
        .map(|rs| {
            let (file, line) = lookup_location(file_index, rs.position);
            format!("{}:{}", file, line)
        })
        .collect();
    let loc_width = locations.iter().map(|l| l.len()).max().unwrap_or(8).max(8);
    let total_width = 5 + 9 + 9 + 57 + loc_width;
    println!(
        "{:<5}{:<9}{:<9}{:<57}{}",
        "#", "Length", "Count", "Substring", "Location"
    );
    println!("{}", "-".repeat(total_width));
    for (i, (rs, loc)) in results.iter().zip(locations.iter()).enumerate() {
        println!(
            "{:<5}{:<9}{:<9}{:<57}{}",
            i + 1,
            rs.length,
            rs.count,
            format_substring(50, &rs.substring),
            loc
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

fn collapse_whitespace(s: &str) -> (String, Vec<usize>) {
    let mut result = String::with_capacity(s.len());
    let mut pos_map = Vec::with_capacity(s.len());
    let mut in_ws = false;
    for (i, c) in s.chars().enumerate() {
        if c == '\0' {
            in_ws = false;
            result.push(c);
            pos_map.push(i);
        } else if c.is_whitespace() {
            if !in_ws {
                result.push(' ');
                pos_map.push(i);
                in_ws = true;
            }
        } else {
            in_ws = false;
            result.push(c);
            pos_map.push(i);
        }
    }
    (result, pos_map)
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
