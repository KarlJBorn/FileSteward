/// Convention inference for directory rationalization.
///
/// Classifies folder naming conventions, detects the dominant convention
/// among a set of sibling folders, and proposes rename targets for outliers.
///
/// Design principle: conservative flagging. If a name contains tokens that
/// cannot be confidently classified (ambiguous ALL_CAPS, date-like sequences,
/// version strings), the name is not flagged. Only clear-cut outliers surface
/// as findings.

// ---------------------------------------------------------------------------
// Naming convention enum
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NamingConvention {
    /// "My Documents", "Old Projects"
    TitleCase,
    /// "my_documents", "old_projects"
    SnakeCase,
    /// "myDocuments", "oldProjects"
    CamelCase,
    /// "my-documents", "old-projects"
    KebabCase,
    /// "documents", "projects"
    LowerCase,
    /// Cannot be confidently classified — do not flag
    Unknown,
}

// ---------------------------------------------------------------------------
// Token classification
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    /// A normal word — apply target convention
    Word(String),
    /// A date appendix segment preserved as-is, e.g. "2000_01_24"
    DateAppendix(String),
    /// A standalone date part — year, month, or day preserved as-is
    DatePart(String),
    /// A version string preserved as-is, e.g. "v3", "v12"
    Version(String),
    /// Unclassifiable — presence causes the name to be skipped
    Ambiguous(String),
}

/// Returns true if the string looks like a 4-digit year (1900–2099).
fn is_year(s: &str) -> bool {
    if s.len() != 4 {
        return false;
    }
    matches!(s.get(..2), Some("19") | Some("20"))
        && s.chars().all(|c| c.is_ascii_digit())
}

/// Returns true if the string looks like a month or day (1–2 digits, value ≤ 31).
fn is_month_or_day(s: &str) -> bool {
    if s.len() > 2 || s.is_empty() {
        return false;
    }
    s.chars().all(|c| c.is_ascii_digit())
        && s.parse::<u32>().map(|n| n >= 1 && n <= 31).unwrap_or(false)
}

/// Returns true if the string is purely numeric.
fn is_numeric(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

/// Returns true if the string looks like a version tag: v followed by digits.
fn is_version(s: &str) -> bool {
    s.len() >= 2
        && s.starts_with('v')
        && s[1..].chars().all(|c| c.is_ascii_digit())
}

/// Returns true if the string is all uppercase ASCII letters only (no digits,
/// no punctuation) and within the length range that suggests an acronym.
/// We treat 2–4 char all-caps letter sequences as potentially ambiguous
/// (could be acronym like "HP" or stylistic like "OLD").
fn is_ambiguous_caps(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 4
        && s.chars().all(|c| c.is_ascii_uppercase())
}

/// Classify a raw underscore- or hyphen-delimited token into a typed Token.
fn classify_raw_token(raw: &str) -> Token {
    if raw.is_empty() {
        return Token::Ambiguous(raw.to_string());
    }
    if is_version(raw) {
        return Token::Version(raw.to_string());
    }
    if is_year(raw) {
        return Token::DatePart(raw.to_string());
    }
    if is_month_or_day(raw) {
        return Token::DatePart(raw.to_string());
    }
    if is_numeric(raw) {
        // Longer numeric strings that aren't years or dates — ambiguous
        return Token::Ambiguous(raw.to_string());
    }
    if is_ambiguous_caps(raw) {
        return Token::Ambiguous(raw.to_string());
    }
    // All-lowercase or Title-cased words are safe to reclassify
    let is_plain_word = raw.chars().all(|c| c.is_ascii_lowercase())
        || (raw.chars().next().map(|c| c.is_ascii_uppercase()).unwrap_or(false)
            && raw.chars().skip(1).all(|c| c.is_ascii_lowercase()));
    if is_plain_word {
        return Token::Word(raw.to_lowercase());
    }
    // Anything else (mixed case, ALL_CAPS long words, etc.) — skip
    Token::Ambiguous(raw.to_string())
}

/// Attempt to detect a date appendix within a slice of consecutive date parts.
/// If we have 2–3 consecutive DatePart tokens, merge them back into a
/// DateAppendix preserving the original separator.
fn merge_date_parts(tokens: Vec<Token>, sep: char) -> Vec<Token> {
    let mut result: Vec<Token> = Vec::new();
    let mut date_run: Vec<String> = Vec::new();

    let flush = |run: &mut Vec<String>, out: &mut Vec<Token>, sep: char| {
        if run.len() >= 2 {
            out.push(Token::DateAppendix(run.join(&sep.to_string())));
        } else if run.len() == 1 {
            out.push(Token::DatePart(run[0].clone()));
        }
        run.clear();
    };

    for token in tokens {
        match token {
            Token::DatePart(s) => date_run.push(s),
            other => {
                flush(&mut date_run, &mut result, sep);
                result.push(other);
            }
        }
    }
    flush(&mut date_run, &mut result, sep);
    result
}

// ---------------------------------------------------------------------------
// Convention classification
// ---------------------------------------------------------------------------

/// Classify the naming convention of a single folder name.
/// Returns `Unknown` if the name cannot be confidently classified.
pub fn classify_convention(name: &str) -> NamingConvention {
    if name.is_empty() {
        return NamingConvention::Unknown;
    }

    // Detect separator
    let has_underscore = name.contains('_');
    let has_hyphen = name.contains('-');
    let has_space = name.contains(' ');

    // Names with mixed separators are ambiguous
    let separator_count = [has_underscore, has_hyphen, has_space]
        .iter()
        .filter(|&&b| b)
        .count();
    if separator_count > 1 {
        return NamingConvention::Unknown;
    }

    if has_underscore {
        return classify_underscore(name);
    }
    if has_hyphen {
        return classify_hyphen(name);
    }
    if has_space {
        return classify_space_separated(name);
    }
    classify_single_word(name)
}

fn classify_underscore(name: &str) -> NamingConvention {
    let parts: Vec<&str> = name.split('_').collect();
    // All parts must be classifiable (not ambiguous) for a confident verdict
    let tokens: Vec<Token> = parts.iter().map(|p| classify_raw_token(p)).collect();
    let tokens = merge_date_parts(tokens, '_');
    let has_ambiguous = tokens
        .iter()
        .any(|t| matches!(t, Token::Ambiguous(_)));
    if has_ambiguous {
        return NamingConvention::Unknown;
    }
    // If all word tokens are lowercase (or date/version), it's snake_case
    NamingConvention::SnakeCase
}

fn classify_hyphen(name: &str) -> NamingConvention {
    let parts: Vec<&str> = name.split('-').collect();
    let tokens: Vec<Token> = parts.iter().map(|p| classify_raw_token(p)).collect();
    let has_ambiguous = tokens
        .iter()
        .any(|t| matches!(t, Token::Ambiguous(_)));
    if has_ambiguous {
        return NamingConvention::Unknown;
    }
    NamingConvention::KebabCase
}

fn classify_space_separated(name: &str) -> NamingConvention {
    let words: Vec<&str> = name.split(' ').collect();
    if words.is_empty() {
        return NamingConvention::Unknown;
    }

    let mut all_title = true;
    let mut all_lower = true;

    for word in &words {
        if word.is_empty() {
            return NamingConvention::Unknown; // double space
        }
        // Allow date parts and version tags within space-separated names
        if is_year(word) || is_month_or_day(word) || is_version(word) || is_numeric(word) {
            continue;
        }
        // Ambiguous ALL_CAPS short words — skip confidently classifying
        if is_ambiguous_caps(word) {
            return NamingConvention::Unknown;
        }
        let starts_upper = word.chars().next().map(|c| c.is_ascii_uppercase()).unwrap_or(false);
        let rest_lower = word.chars().skip(1).all(|c| c.is_ascii_lowercase());
        let all_word_lower = word.chars().all(|c| c.is_ascii_lowercase());

        if !(starts_upper && rest_lower) {
            all_title = false;
        }
        if !all_word_lower {
            all_lower = false;
        }
    }

    if all_title {
        NamingConvention::TitleCase
    } else if all_lower {
        NamingConvention::LowerCase
    } else {
        NamingConvention::Unknown
    }
}

fn classify_single_word(name: &str) -> NamingConvention {
    if name.chars().all(|c| c.is_ascii_lowercase()) {
        return NamingConvention::LowerCase;
    }
    // Detect camelCase: starts lowercase, contains at least one uppercase
    let starts_lower = name.chars().next().map(|c| c.is_ascii_lowercase()).unwrap_or(false);
    let has_upper_inside = name.chars().skip(1).any(|c| c.is_ascii_uppercase());
    if starts_lower && has_upper_inside {
        // Make sure the name is otherwise just letters (no digits mid-name etc.)
        if name.chars().all(|c| c.is_ascii_alphabetic()) {
            return NamingConvention::CamelCase;
        }
    }
    // Single Title-cased word (starts upper, rest lower)
    let starts_upper = name.chars().next().map(|c| c.is_ascii_uppercase()).unwrap_or(false);
    let rest_lower = name.chars().skip(1).all(|c| c.is_ascii_lowercase());
    if starts_upper && rest_lower {
        return NamingConvention::TitleCase;
    }
    NamingConvention::Unknown
}

// ---------------------------------------------------------------------------
// Dominant convention detection
// ---------------------------------------------------------------------------

/// Find the dominant naming convention among a slice of folder names.
/// Returns `None` if no convention reaches the confidence threshold,
/// or if fewer than `min_samples` classifiable names are present.
pub fn dominant_convention(
    names: &[&str],
    threshold: f64,
    min_samples: usize,
) -> Option<NamingConvention> {
    use std::collections::HashMap;

    let mut counts: HashMap<NamingConvention, usize> = HashMap::new();
    let mut classifiable = 0usize;

    for name in names {
        let conv = classify_convention(name);
        if conv != NamingConvention::Unknown {
            *counts.entry(conv).or_insert(0) += 1;
            classifiable += 1;
        }
    }

    if classifiable < min_samples {
        return None;
    }

    counts
        .into_iter()
        .filter(|(_, count)| *count as f64 / classifiable as f64 >= threshold)
        .max_by_key(|(_, count)| *count)
        .map(|(conv, _)| conv)
}

// ---------------------------------------------------------------------------
// Rename suggestion
// ---------------------------------------------------------------------------

/// Given a folder name and a target convention, suggest a renamed version.
/// Returns `None` if the name cannot be safely converted (ambiguous tokens).
pub fn suggest_rename(name: &str, target: NamingConvention) -> Option<String> {
    // Determine the separator used in the source name
    let sep = if name.contains('_') {
        Some('_')
    } else if name.contains('-') {
        Some('-')
    } else if name.contains(' ') {
        Some(' ')
    } else {
        None
    };

    // Tokenize
    let tokens: Vec<Token> = match sep {
        Some(s) => {
            let parts: Vec<Token> = name.split(s).map(classify_raw_token).collect();
            merge_date_parts(parts, s)
        }
        None => {
            // Single word or camelCase
            let words = split_camel_case(name);
            words
                .into_iter()
                .map(|w| classify_raw_token(&w))
                .collect()
        }
    };

    // If any token is ambiguous, don't suggest a rename
    if tokens.iter().any(|t| matches!(t, Token::Ambiguous(_))) {
        return None;
    }

    // Reconstruct using target convention
    let segments: Vec<String> = tokens
        .iter()
        .map(|t| match t {
            Token::Word(w) => apply_word_case(w, target),
            Token::DateAppendix(s) => s.clone(), // preserve separator and all
            Token::DatePart(s) => s.clone(),
            Token::Version(s) => s.clone(),
            Token::Ambiguous(s) => s.clone(), // unreachable after guard above
        })
        .collect();

    let result = match target {
        NamingConvention::TitleCase => segments.join(" "),
        NamingConvention::SnakeCase => segments.join("_"),
        NamingConvention::KebabCase => segments.join("-"),
        NamingConvention::LowerCase => segments.join(" "),
        NamingConvention::CamelCase => {
            // First word lowercase, rest title-cased
            segments
                .iter()
                .enumerate()
                .map(|(i, s)| {
                    if i == 0 {
                        s.to_lowercase()
                    } else {
                        let mut c = s.chars();
                        match c.next() {
                            None => String::new(),
                            Some(f) => f.to_uppercase().to_string() + c.as_str(),
                        }
                    }
                })
                .collect::<Vec<_>>()
                .join("")
        }
        NamingConvention::Unknown => return None,
    };

    // Only return if the result is actually different
    if result == name {
        None
    } else {
        Some(result)
    }
}

fn apply_word_case(word: &str, convention: NamingConvention) -> String {
    match convention {
        NamingConvention::TitleCase | NamingConvention::CamelCase => {
            let mut c = word.chars();
            match c.next() {
                None => String::new(),
                Some(f) => f.to_uppercase().to_string() + &c.as_str().to_lowercase(),
            }
        }
        NamingConvention::SnakeCase
        | NamingConvention::KebabCase
        | NamingConvention::LowerCase => word.to_lowercase(),
        NamingConvention::Unknown => word.to_string(),
    }
}

/// Split a camelCase or PascalCase string into lowercase words.
fn split_camel_case(name: &str) -> Vec<String> {
    let mut words: Vec<String> = Vec::new();
    let mut current = String::new();
    for ch in name.chars() {
        if ch.is_ascii_uppercase() && !current.is_empty() {
            words.push(current.to_lowercase());
            current = ch.to_string();
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        words.push(current.to_lowercase());
    }
    words
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- classify_convention ---

    #[test]
    fn test_title_case_two_words() {
        assert_eq!(classify_convention("My Documents"), NamingConvention::TitleCase);
    }

    #[test]
    fn test_title_case_single_word() {
        assert_eq!(classify_convention("Documents"), NamingConvention::TitleCase);
    }

    #[test]
    fn test_title_case_three_words() {
        assert_eq!(classify_convention("Old Photo Archive"), NamingConvention::TitleCase);
    }

    #[test]
    fn test_snake_case_simple() {
        assert_eq!(classify_convention("my_documents"), NamingConvention::SnakeCase);
    }

    #[test]
    fn test_snake_case_with_year() {
        // Year is a DatePart — not ambiguous — so the name is still SnakeCase
        assert_eq!(classify_convention("backup_2023"), NamingConvention::SnakeCase);
    }

    #[test]
    fn test_snake_case_with_date_appendix() {
        // Full date appendix should not make the name Unknown
        assert_eq!(classify_convention("Born_Family_2000_01_24"), NamingConvention::SnakeCase);
    }

    #[test]
    fn test_camel_case() {
        assert_eq!(classify_convention("myDocuments"), NamingConvention::CamelCase);
    }

    #[test]
    fn test_camel_case_photo_archive() {
        assert_eq!(classify_convention("photoArchive"), NamingConvention::CamelCase);
    }

    #[test]
    fn test_kebab_case() {
        assert_eq!(classify_convention("my-documents"), NamingConvention::KebabCase);
    }

    #[test]
    fn test_lowercase_single() {
        assert_eq!(classify_convention("documents"), NamingConvention::LowerCase);
    }

    #[test]
    fn test_all_caps_short_is_unknown() {
        // "OLD" is ambiguous — could be acronym or stylistic
        assert_eq!(classify_convention("OLD"), NamingConvention::Unknown);
    }

    #[test]
    fn test_all_caps_in_snake_is_unknown() {
        // "OLD_files" — "OLD" token is ambiguous
        assert_eq!(classify_convention("OLD_files"), NamingConvention::Unknown);
    }

    #[test]
    fn test_kodak_pictures_is_unknown() {
        // "KODAK" is ambiguous short all-caps within a space-separated name
        assert_eq!(classify_convention("KODAK Pictures"), NamingConvention::Unknown);
    }

    #[test]
    fn test_hp_backup_is_unknown() {
        assert_eq!(classify_convention("HP Backup"), NamingConvention::Unknown);
    }

    #[test]
    fn test_mixed_separators_is_unknown() {
        assert_eq!(classify_convention("my_docs-backup"), NamingConvention::Unknown);
    }

    #[test]
    fn test_empty_is_unknown() {
        assert_eq!(classify_convention(""), NamingConvention::Unknown);
    }

    #[test]
    fn test_version_only_is_unknown() {
        // "v3" alone — no words to infer convention from
        assert_eq!(classify_convention("v3"), NamingConvention::Unknown);
    }

    // --- dominant_convention ---

    #[test]
    fn test_dominant_title_case() {
        let names = vec!["Finance", "Old Projects", "Personal", "Media", "Work"];
        let dom = dominant_convention(&names, 0.8, 3);
        assert_eq!(dom, Some(NamingConvention::TitleCase));
    }

    #[test]
    fn test_dominant_snake_case() {
        let names = vec!["my_docs", "old_photos", "backup_2023", "temp_files"];
        let dom = dominant_convention(&names, 0.8, 3);
        assert_eq!(dom, Some(NamingConvention::SnakeCase));
    }

    #[test]
    fn test_dominant_none_when_mixed() {
        // Even mix of TitleCase and snake_case — no dominant
        let names = vec!["My Docs", "old_photos", "Finance", "backup_files"];
        let dom = dominant_convention(&names, 0.8, 3);
        assert_eq!(dom, None);
    }

    #[test]
    fn test_dominant_none_when_too_few_samples() {
        let names = vec!["Finance", "Media"];
        let dom = dominant_convention(&names, 0.8, 3);
        assert_eq!(dom, None);
    }

    #[test]
    fn test_dominant_ignores_unknown_names() {
        // "HP Backup" and "KODAK Pictures" are Unknown — ignored in count
        // The remaining three are TitleCase — should still dominate
        let names = vec!["Finance", "Old Projects", "Personal", "HP Backup", "KODAK Pictures"];
        let dom = dominant_convention(&names, 0.8, 3);
        assert_eq!(dom, Some(NamingConvention::TitleCase));
    }

    #[test]
    fn test_dominant_one_outlier_still_dominant() {
        // 4 Title Case, 1 snake_case outlier — TitleCase still dominates at 80%
        let names = vec!["Finance", "Old Projects", "Personal", "Media", "old_receipts"];
        let dom = dominant_convention(&names, 0.8, 3);
        assert_eq!(dom, Some(NamingConvention::TitleCase));
    }

    // --- suggest_rename ---

    #[test]
    fn test_rename_snake_to_title() {
        assert_eq!(
            suggest_rename("old_receipts", NamingConvention::TitleCase),
            Some("Old Receipts".to_string())
        );
    }

    #[test]
    fn test_rename_camel_to_title() {
        assert_eq!(
            suggest_rename("photoArchive", NamingConvention::TitleCase),
            Some("Photo Archive".to_string())
        );
    }

    #[test]
    fn test_rename_kebab_to_title() {
        assert_eq!(
            suggest_rename("my-documents", NamingConvention::TitleCase),
            Some("My Documents".to_string())
        );
    }

    #[test]
    fn test_rename_title_to_snake() {
        assert_eq!(
            suggest_rename("My Documents", NamingConvention::SnakeCase),
            Some("my_documents".to_string())
        );
    }

    #[test]
    fn test_rename_preserves_date_appendix() {
        assert_eq!(
            suggest_rename("Born_Family_2000_01_24", NamingConvention::TitleCase),
            Some("Born Family 2000_01_24".to_string())
        );
    }

    #[test]
    fn test_rename_preserves_year() {
        assert_eq!(
            suggest_rename("backup_2023", NamingConvention::TitleCase),
            Some("Backup 2023".to_string())
        );
    }

    #[test]
    fn test_rename_preserves_version() {
        assert_eq!(
            suggest_rename("project_v3", NamingConvention::TitleCase),
            Some("Project v3".to_string())
        );
    }

    #[test]
    fn test_rename_returns_none_for_ambiguous() {
        // "OLD_files" has an ambiguous token — no rename suggested
        assert_eq!(suggest_rename("OLD_files", NamingConvention::TitleCase), None);
    }

    #[test]
    fn test_rename_returns_none_when_already_correct() {
        // Already Title Case — no change needed
        assert_eq!(
            suggest_rename("Old Receipts", NamingConvention::TitleCase),
            None
        );
    }

    // --- split_camel_case ---

    #[test]
    fn test_split_camel_case_simple() {
        assert_eq!(split_camel_case("photoArchive"), vec!["photo", "archive"]);
    }

    #[test]
    fn test_split_camel_case_pascal() {
        assert_eq!(split_camel_case("OldProjects"), vec!["old", "projects"]);
    }

    #[test]
    fn test_split_camel_case_single_word() {
        assert_eq!(split_camel_case("documents"), vec!["documents"]);
    }
}
