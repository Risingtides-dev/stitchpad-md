//! Minimal inline markdown → ratatui Spans. Ponytail scope (dennis's parse boundary):
//! only **bold**, *italic*, `code`, and `- ` bullets. Everything else is plain text —
//! no links, tables, blockquotes, nesting, HTML, or headers (YAGNI for a chat pad).
//!
//! `!img: /path` lines are detected separately (see `image_path`) so the widget can
//! show a muted `[image: …]` placeholder.

use ratatui::{
    style::{Modifier, Style},
    text::Span,
};

/// If `line` is an image directive (`!img: <path>`), return the trimmed path.
pub fn image_path(line: &str) -> Option<&str> {
    line.trim().strip_prefix("!img:").map(|p| p.trim())
}

/// Parse one body line into styled spans. A leading `- ` becomes a `• ` bullet.
/// Markers must be paired on the same line; an unmatched marker is left literal.
pub fn parse_line(line: &str) -> Vec<Span<'static>> {
    let mut spans: Vec<Span> = Vec::new();

    // bullet prefix: "- foo" / "* foo" (list, not italic) → "• foo"
    let body = if let Some(rest) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) {
        spans.push(Span::styled(
            "• ",
            Style::default().fg(crate::theme::t().faint),
        ));
        rest
    } else {
        line
    };

    let chars: Vec<char> = body.chars().collect();
    let mut i = 0;
    let mut plain = String::new();

    // flush accumulated plain text as a default-styled span
    macro_rules! flush_plain {
        () => {
            if !plain.is_empty() {
                spans.push(Span::raw(std::mem::take(&mut plain)));
            }
        };
    }

    while i < chars.len() {
        // try each marker; emit a styled span if a matching close exists ahead.
        if let Some((len, inner, style)) = match_marker(&chars, i) {
            flush_plain!();
            spans.push(Span::styled(inner, style));
            i += len;
        } else {
            plain.push(chars[i]);
            i += 1;
        }
    }
    flush_plain!();
    if spans.is_empty() {
        spans.push(Span::raw(String::new()));
    }
    spans
}

/// At position `i`, if a `**`, `*`, or `` ` `` run opens and closes later on the line,
/// return (consumed_len, inner_text, style). Longest marker (`**`) is tried first.
fn match_marker(chars: &[char], i: usize) -> Option<(usize, String, Style)> {
    // **bold**
    if chars[i..].starts_with(&['*', '*']) {
        if let Some(end) = find_close(chars, i + 2, &['*', '*']) {
            let inner: String = chars[i + 2..end].iter().collect();
            return Some((
                end + 2 - i,
                inner,
                Style::default().add_modifier(Modifier::BOLD),
            ));
        }
    }
    // *italic*  (single star; ensure it's not the start of **)
    if chars[i] == '*' && chars.get(i + 1) != Some(&'*') {
        if let Some(end) = find_close(chars, i + 1, &['*']) {
            let inner: String = chars[i + 1..end].iter().collect();
            return Some((
                end + 1 - i,
                inner,
                Style::default().add_modifier(Modifier::ITALIC),
            ));
        }
    }
    // `code`
    if chars[i] == '`' {
        if let Some(end) = find_close(chars, i + 1, &['`']) {
            let inner: String = chars[i + 1..end].iter().collect();
            return Some((
                end + 1 - i,
                inner,
                Style::default().fg(crate::theme::t().warn),
            ));
        }
    }
    None
}

/// Find the start index of the next occurrence of `marker` at/after `from`. Returns
/// the index of the marker's first char, or None. Requires non-empty content between.
fn find_close(chars: &[char], from: usize, marker: &[char]) -> Option<usize> {
    let mut j = from;
    while j + marker.len() <= chars.len() {
        if chars[j..].starts_with(marker) && j > from {
            return Some(j);
        }
        j += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(spans: &[Span]) -> Vec<String> {
        spans.iter().map(|s| s.content.to_string()).collect()
    }

    #[test]
    fn bold_italic_code_split_into_spans() {
        let s = parse_line("a **b** c *d* `e`");
        // segments: "a ", "b", " c ", "d", " ", "e"
        assert_eq!(texts(&s), vec!["a ", "b", " c ", "d", " ", "e"]);
        // styles applied where expected (code color comes from the live theme —
        // theme state is global and tests run in parallel, so assert presence,
        // not a specific palette value)
        assert!(s[1].style.add_modifier.contains(Modifier::BOLD));
        assert!(s[3].style.add_modifier.contains(Modifier::ITALIC));
        assert!(s[5].style.fg.is_some());
    }

    #[test]
    fn unmatched_marker_stays_literal() {
        let s = parse_line("just * a lonely star");
        assert_eq!(texts(&s).concat(), "just * a lonely star");
    }

    #[test]
    fn bullet_prefix_becomes_dot() {
        let s = parse_line("- item one");
        assert_eq!(s[0].content, "• ");
        assert_eq!(texts(&s).concat(), "• item one");
    }

    #[test]
    fn image_directive_detected() {
        assert_eq!(image_path("!img: /tmp/x.png"), Some("/tmp/x.png"));
        assert_eq!(image_path("not an image"), None);
    }
}
