use std::fs;

#[test]
fn single_file_long_repeated_substring() {
    let txt = fs::read_to_string("test-data/single.txt").unwrap();
    let sa = lrs::suffix_array::build_suffix_array(&txt);
    let results = lrs::search::find_top_repeated(3, 2, &sa);

    assert!(!results.is_empty(), "expected at least one result");
    let top = &results[0];
    assert_eq!(top.substring, "DEADBEEF CAFEBABE 0123456789 ");
    assert_eq!(top.length, 29);
    assert_eq!(top.count, 2);
}

#[test]
fn short_repeated_substrings_only() {
    let txt = fs::read_to_string("test-data/short.txt").unwrap();
    let sa = lrs::suffix_array::build_suffix_array(&txt);
    let results = lrs::search::find_top_repeated(10, 2, &sa);

    assert!(!results.is_empty());
    assert!(
        results.iter().all(|r| r.length == 2),
        "all results should have length 2"
    );
    let subs: Vec<&str> = results.iter().map(|r| r.substring.as_str()).collect();
    assert!(subs.contains(&"x "), "should contain 'x '");
    assert!(subs.contains(&"y "), "should contain 'y '");
}

#[test]
fn repeated_substring_across_directory_hierarchy() {
    let files = [
        "test-data/project/src/alpha.txt",
        "test-data/project/src/beta.txt",
        "test-data/project/lib/gamma.txt",
        "test-data/project/lib/delta.txt",
    ];
    let contents: Vec<String> = files
        .iter()
        .map(|f| fs::read_to_string(f).unwrap())
        .collect();
    let combined = contents.join("\0") + "\0";
    let sa = lrs::suffix_array::build_suffix_array(&combined);
    let results = lrs::search::find_top_repeated(3, 2, &sa);

    assert!(!results.is_empty(), "expected at least one result");
    let top = &results[0];
    assert_eq!(top.length, 67);
    assert!(
        top.substring
            .starts_with("The quick brown fox jumped over the lazy dog near the riverbank."),
    );
    assert_eq!(top.count, 2);
}
