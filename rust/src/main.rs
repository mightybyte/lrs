use clap::Parser;
use lrs::search::{find_top_repeated, RepeatedSubstring};
use lrs::suffix_tree::{build_suffix_tree, load_suffix_tree, save_suffix_tree};
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

    /// Cache the suffix tree to FILE for faster subsequent runs
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

    let tree = match &opts.cache {
        Some(cache_path) if cache_path.exists() => {
            println!("Loading cached suffix tree from {}", cache_path.display());
            match load_suffix_tree(cache_path) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("Error loading cache: {e}");
                    process::exit(1);
                }
            }
        }
        cache_opt => {
            let t = build_from_files(&files);
            if let Some(cache_path) = cache_opt {
                if let Err(e) = save_suffix_tree(cache_path, &t) {
                    eprintln!("Warning: failed to save cache: {e}");
                } else {
                    println!("Saved suffix tree cache to {}", cache_path.display());
                }
            }
            t
        }
    };

    let results = find_top_repeated(opts.top_n, opts.min_length, &tree);

    println!("Analyzed {} file(s)", files.len());
    println!();

    if results.is_empty() {
        println!("No repeated substrings found.");
    } else {
        print_results(&results);
    }
}

fn build_from_files(files: &[PathBuf]) -> lrs::suffix_tree::SuffixTree {
    let mut parts: Vec<String> = Vec::new();
    for f in files {
        match fs::read_to_string(f) {
            Ok(contents) => parts.push(contents),
            Err(e) => {
                eprintln!("Warning: could not read {}: {e}", f.display());
            }
        }
    }
    let combined = parts.join("\0");
    let combined = combined + "\0";
    build_suffix_tree(&combined)
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

fn resolve_files(recursive: bool, paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for p in paths {
        if p.is_file() {
            files.push(p.clone());
        } else if p.is_dir() {
            if recursive {
                get_files_recursive(p, &mut files);
            } else if let Ok(entries) = fs::read_dir(p) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_file() {
                        files.push(path);
                    }
                }
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
    for entry in WalkDir::new(dir).into_iter().filter_map(|e| e.ok()) {
        if entry.file_type().is_file() {
            files.push(entry.into_path());
        }
    }
}
