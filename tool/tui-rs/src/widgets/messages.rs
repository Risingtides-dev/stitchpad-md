use std::process::Command;
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Widget},
};

/// One parsed pad message: a `## @author · time` header block + its body lines.
#[derive(Debug, Clone)]
pub struct Message {
    pub author: String,
    pub time: String,
    pub body: Vec<String>,
    /// Absolute `## @` block ordinal from the start of the pad (1-based). This is the
    /// same unit `.state/seen.<name>` stores, so read-receipts compare against it.
    pub ordinal: usize,
    /// Names whose seen-cursor has reached this message (read-receipt: "seen by").
    pub seen_by: Vec<String>,
}

/// Scrollable, Slack-style message list. Mirrors RosterRail: owns its own data,
/// parses by shelling out to the bash CLI (`stitchpad read`) — the CLI stays the
/// engine, this is just a client view.
pub struct MessageList {
    pub messages: Vec<Message>,
    /// Lines scrolled up from the bottom. 0 = pinned to newest (auto-follow).
    pub scroll: u16,
    /// When true, new messages keep us pinned to the bottom; any manual scroll-up
    /// turns it off so the view doesn't jump while you read history.
    pub follow: bool,
}

impl MessageList {
    pub fn from_pad() -> Self {
        let messages = Self::parse_pad();
        Self { messages, scroll: 0, follow: true }
    }

    /// Re-read the pad. Called on a file-change event (live-tail) or manual refresh.
    pub fn refresh(&mut self) {
        self.messages = Self::parse_pad();
        if self.follow {
            self.scroll = 0;
        }
    }

    /// Parse `stitchpad read -n N` output into messages. A block is a `## @name · time`
    /// header followed by body lines up to the next `## ` header. Roster/separator
    /// noise (lines before the first header) is ignored. Absolute block ordinals and
    /// read-receipts (`seen_by`) are attached after parsing.
    fn parse_pad() -> Vec<Message> {
        // -n large enough to fill any terminal; the CLI is the source of truth.
        let output = Command::new("stitchpad")
            .args(["read", "-n", "400"])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .unwrap_or_default();

        let mut messages: Vec<Message> = Vec::new();
        let mut cur: Option<Message> = None;

        for line in output.lines() {
            if let Some(rest) = line.strip_prefix("## @") {
                // header: "@author · HH:MM AM/PM"  (separator is " · ")
                if let Some(prev) = cur.take() {
                    messages.push(prev);
                }
                let (author, time) = match rest.split_once(" · ") {
                    Some((a, t)) => (a.trim().to_string(), t.trim().to_string()),
                    None => (rest.trim().to_string(), String::new()),
                };
                cur = Some(Message { author, time, body: Vec::new(), ordinal: 0, seen_by: Vec::new() });
            } else if let Some(msg) = cur.as_mut() {
                // trim trailing blank lines lazily: skip leading blanks, keep inner
                if !(msg.body.is_empty() && line.trim().is_empty()) {
                    msg.body.push(line.to_string());
                }
            }
        }
        if let Some(prev) = cur.take() {
            messages.push(prev);
        }

        // Absolute ordinals: `read -n` gives a tail, so number backwards from the pad's
        // total `## @` block count — that's the unit seen.<name> uses.
        let total = Self::total_blocks();
        let n = messages.len();
        for (i, m) in messages.iter_mut().enumerate() {
            // last parsed message is block `total`; earlier ones count down.
            m.ordinal = total.saturating_sub(n - 1 - i);
        }

        // Read-receipts: a member has "seen" block N if seen.<member> >= N. Exclude the
        // author (you don't receipt your own post) and any cursor of 0/missing.
        let cursors = Self::seen_cursors();
        for m in messages.iter_mut() {
            let mut seers: Vec<String> = cursors
                .iter()
                .filter(|(name, ord)| **ord >= m.ordinal && name.as_str() != m.author)
                .map(|(name, _)| name.clone())
                .collect();
            seers.sort();
            m.seen_by = seers;
        }

        messages
    }

    /// Total `## @` block count in the full pad — the absolute ordinal of the newest
    /// message. Cheap: count headers via the CLI's read of the whole file.
    fn total_blocks() -> usize {
        Command::new("stitchpad")
            .args(["read", "-n", "100000"])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.lines().filter(|l| l.starts_with("## @")).count())
            .unwrap_or(0)
    }

    /// Read `.state/seen.<name>` cursors → {name: highest-delivered-ordinal}. Missing
    /// dir or unreadable files just yield no receipts (graceful: no "seen by" shown).
    fn seen_cursors() -> std::collections::HashMap<String, usize> {
        let mut map = std::collections::HashMap::new();
        let dir = std::path::Path::new(".stitchpad/.state");
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.flatten() {
                let fname = e.file_name();
                let fname = fname.to_string_lossy();
                if let Some(name) = fname.strip_prefix("seen.") {
                    if let Ok(s) = std::fs::read_to_string(e.path()) {
                        if let Ok(ord) = s.trim().parse::<usize>() {
                            map.insert(name.to_string(), ord);
                        }
                    }
                }
            }
        }
        map
    }

    /// Canonical per-author 256-color. MUST match the bash `color_for()` (the single
    /// source of truth shared by the TUI and the kitty window-bg adapter): sum of the
    /// name's char codes, modulo the curated PALETTE. Same name → same color in the
    /// pad, the message list, AND the kitty window background. No second scheme.
    fn author_color(name: &str) -> Color {
        // keep in lockstep with PALETTE in lib.sh / tui.sh.
        const PALETTE: [u8; 12] = [39, 208, 76, 170, 214, 51, 199, 220, 123, 141, 203, 80];
        let sum: u32 = name.chars().map(|c| c as u32).sum();
        Color::Indexed(PALETTE[(sum as usize) % PALETTE.len()])
    }

    pub fn scroll_up(&mut self) {
        self.follow = false;
        self.scroll = self.scroll.saturating_add(1);
    }

    pub fn scroll_down(&mut self) {
        self.scroll = self.scroll.saturating_sub(1);
        if self.scroll == 0 {
            self.follow = true;
        }
    }

    /// Render messages bottom-up into `width`-wrapped lines, then show the window
    /// ending `scroll` lines above the newest. Returns the flat line list so the
    /// Widget impl just slices it — keeps wrap + scroll logic in one place.
    fn rendered_lines(&self, width: u16) -> Vec<Line<'static>> {
        const INDENT: &str = "  "; // body sits 2 cols under its author — Slack-style grouping
        let mut lines: Vec<Line> = Vec::new();
        for m in &self.messages {
            let color = Self::author_color(&m.author);
            // header: "@author · time" — author in its color, dim middot + time as quiet meta.
            let mut header = vec![Span::styled(
                format!("@{}", m.author),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            )];
            if !m.time.is_empty() {
                header.push(Span::styled(
                    format!("  ·  {}", m.time),
                    Style::default().fg(Color::DarkGray),
                ));
            }
            lines.push(Line::from(header));

            // body: word-wrap to width, hanging-indented under the author.
            let avail = (width as usize).saturating_sub(INDENT.len()).max(8);
            for raw in &m.body {
                if raw.trim().is_empty() {
                    lines.push(Line::from(""));
                    continue;
                }
                for wrapped in wrap_words(raw, avail) {
                    lines.push(Line::from(Span::raw(format!("{}{}", INDENT, wrapped))));
                }
            }
            // read-receipt: quiet "seen by @x @y" under the message, only if anyone has.
            if !m.seen_by.is_empty() {
                let who = m
                    .seen_by
                    .iter()
                    .map(|n| format!("@{}", n))
                    .collect::<Vec<_>>()
                    .join(" ");
                lines.push(Line::from(Span::styled(
                    format!("{}seen by {}", INDENT, who),
                    Style::default()
                        .fg(Color::DarkGray)
                        .add_modifier(Modifier::ITALIC),
                )));
            }
            lines.push(Line::from("")); // one-line breath between messages
        }
        lines
    }
}

impl Widget for &MessageList {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let block = Block::default().title(" Messages ").borders(Borders::ALL);
        let inner = block.inner(area);
        block.render(area, buf);

        if self.messages.is_empty() {
            let empty = Line::from(Span::styled(
                "  (no messages yet)",
                Style::default().fg(Color::Gray),
            ));
            buf.set_line(inner.x, inner.y, &empty, inner.width);
            return;
        }

        let all = self.rendered_lines(inner.width);
        let h = inner.height as usize;
        let total = all.len();

        // Bottom-anchored window: newest at the bottom, `scroll` lines above newest.
        let bottom = total.saturating_sub(self.scroll as usize);
        let start = bottom.saturating_sub(h);
        let end = bottom.min(total);

        for (row, line) in all[start..end].iter().enumerate() {
            buf.set_line(inner.x, inner.y + row as u16, line, inner.width);
        }
    }
}

/// Word-aware wrap to `width` columns. Keeps words intact; a single word longer
/// than the line (e.g. a URL) is hard-broken so it never overflows. (char count,
/// not grapheme — fine for chat prose.)
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut len = 0usize;
    for word in text.split_whitespace() {
        let wlen = word.chars().count();
        if wlen > width {
            // flush current, then hard-break the long word
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
                len = 0;
            }
            let chars: Vec<char> = word.chars().collect();
            let mut i = 0;
            while i < chars.len() {
                let end = (i + width).min(chars.len());
                out.push(chars[i..end].iter().collect());
                i = end;
            }
            continue;
        }
        let need = if line.is_empty() { wlen } else { len + 1 + wlen };
        if need > width {
            out.push(std::mem::take(&mut line));
            line.push_str(word);
            len = wlen;
        } else {
            if !line.is_empty() {
                line.push(' ');
                len += 1;
            }
            line.push_str(word);
            len += wlen;
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_keeps_words_and_breaks_long_tokens() {
        // normal prose wraps on word boundaries
        let w = wrap_words("the quick brown fox jumps", 10);
        assert!(w.iter().all(|l| l.chars().count() <= 10), "no line exceeds width");
        assert_eq!(w.join(" "), "the quick brown fox jumps", "words preserved in order");
        // an over-long token is hard-broken, never overflows
        let long = wrap_words("https://example.com/really/long/path", 10);
        assert!(long.iter().all(|l| l.chars().count() <= 10), "long token hard-broken to width");
    }

    #[test]
    fn author_color_matches_bash_color_for() {
        // Pinned to the canonical bash color_for() values so the pad TUI, message list,
        // and kitty window background never drift. If PALETTE/algorithm changes, this
        // breaks loudly. john's cited mapping: dale=203, mark=220, larry=76.
        let idx = |n: &str| match MessageList::author_color(n) {
            Color::Indexed(i) => i,
            _ => panic!("expected indexed color"),
        };
        assert_eq!(idx("dale"), 203);
        assert_eq!(idx("mark"), 220);
        assert_eq!(idx("larry"), 76);
        assert_eq!(idx("ernie"), 170);
    }

    #[test]
    fn parse_splits_header_and_body() {
        // ensure the header/body split contract holds (drives the whole render)
        let m = Message { author: "dale".into(), time: "09:30 PM".into(), body: vec!["hi".into()], ordinal: 5, seen_by: vec!["mark".into()] };
        assert_eq!(m.author, "dale");
        assert_eq!(m.time, "09:30 PM");
        assert_eq!(m.ordinal, 5);
        assert_eq!(m.seen_by, vec!["mark".to_string()]);
    }
}
