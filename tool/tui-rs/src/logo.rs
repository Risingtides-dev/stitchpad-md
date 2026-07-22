//! The flock's face. ASCII sheep art (safe glyphs only — parens, quotes, pipes,
//! block/geometry chars every terminal font carries) + the one-line lamb mark
//! that replaced the old ⛵ emoji in the header.
//!
//! Lore glossary, used across the chrome:
//!   the pasture  — the conversation (messages panel)
//!   the flock    — the roster of agents
//!   grazing      — online
//!   the shepherd — the watcher daemon (wakes agents on @mention)
//!   the barn     — the task board
//!   shearing     — compacting the pad (wool off, sheep intact)
//!   ruminating   — summarizing the thread (chewing it over)

use crate::theme;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

/// One-line lamb mark for the 1-row header: two wool bumps + a snout.
pub fn mark() -> Vec<Span<'static>> {
    let t = theme::t();
    vec![
        Span::styled("∩", Style::default().fg(t.wool)),
        Span::styled("ᴥ", Style::default().fg(t.accent)),
        Span::styled("∩", Style::default().fg(t.wool)),
    ]
}

/// The big sheep (ejm heritage, lightly tidied) with a grass line under it.
/// Wool in `wool`, face/legs in `muted`, grass in `ok`. ~22 cols × 9 rows.
pub fn sheep(center_pad: usize) -> Vec<Line<'static>> {
    let t = theme::t();
    let wool = Style::default().fg(t.wool);
    let face = Style::default().fg(t.muted);
    let grass = Style::default().fg(t.ok);
    let pad = " ".repeat(center_pad);
    let w = |s: &str| Line::from(vec![Span::raw(pad.clone()), Span::styled(s.to_string(), wool)]);
    vec![
        w("      __  _"),
        w("  .-:'  `; `-._"),
        w(" (_,           )"),
        Line::from(vec![
            Span::raw(pad.clone()),
            Span::styled(",'o\"(          ", face),
            Span::styled(")>", wool),
        ]),
        Line::from(vec![
            Span::raw(pad.clone()),
            Span::styled("(__,-'", face),
            Span::styled("        )", wool),
        ]),
        w("   (          )"),
        w("    `-'._.--._.'"),
        Line::from(vec![
            Span::raw(pad.clone()),
            Span::styled("       |||  |||", face),
        ]),
        Line::from(vec![
            Span::raw(pad.clone()),
            Span::styled("..,.^..,,.~,,..,..,^,.", grass),
        ]),
    ]
}

/// Empty-state block: the sheep plus a title + hint, all centered-ish.
pub fn empty_state(title: &str, hint: &str, center_pad: usize) -> Vec<Line<'static>> {
    let t = theme::t();
    let pad = " ".repeat(center_pad);
    let mut lines = vec![Line::from("")];
    lines.extend(sheep(center_pad));
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::raw(pad.clone()),
        Span::styled(
            title.to_string(),
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(vec![
        Span::raw(pad),
        Span::styled(hint.to_string(), Style::default().fg(t.muted)),
    ]));
    lines
}
