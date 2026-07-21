mod color;
mod widgets;

use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste,
        EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton,
        MouseEventKind,
    },
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::layout::Rect;
use notify::{RecursiveMode, Watcher};
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
};
use std::io;
use std::io::Write as _;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use widgets::roster::{RosterMember, RosterRail};

/// Chat-first stitchpad TUI.
///
/// The prompt is ALWAYS live on the Chat tab — type and hit Enter, no compose
/// mode. That means plain letters belong to the input, so app actions live on
/// modifiers (^C quit, ^T tasks, ^R refresh, ^Y copy) — the irssi/weechat
/// convention. The Tasks tab has no input, so it keeps plain vim keys.
struct App {
    tab: u8, // 0=Chat 1=Tasks
    input: String,
    /// Cursor position in the input, as a CHAR index (0..=input char len).
    cursor: usize,
    detail_open: bool,
    watcher_alive: bool,
    flash: Option<(String, std::time::Instant)>,
    /// Inner rect of the messages panel from the last draw — mouse events route
    /// by hit-testing against this (drag-select, wheel scroll).
    msg_inner: Rect,
    /// Header tab labels' clickable column ranges from the last draw.
    tab_hits: [(u16, u16); 2],
    /// Live mouse drag anchor (inner-relative row), while the left button is down.
    drag_anchor: Option<u16>,
}

impl App {
    fn flash(&mut self, msg: impl Into<String>) {
        self.flash = Some((msg.into(), std::time::Instant::now()));
    }
    fn flash_line(&self) -> Option<&str> {
        match &self.flash {
            Some((m, t)) if t.elapsed() < Duration::from_secs(3) => Some(m.as_str()),
            _ => None,
        }
    }

    // ── Cursor-aware input editing (char-indexed; input may hold any UTF-8) ──
    fn byte_at(&self, ci: usize) -> usize {
        self.input
            .char_indices()
            .nth(ci)
            .map(|(b, _)| b)
            .unwrap_or(self.input.len())
    }
    fn char_len(&self) -> usize {
        self.input.chars().count()
    }
    fn insert_str(&mut self, s: &str) {
        let b = self.byte_at(self.cursor);
        self.input.insert_str(b, s);
        self.cursor += s.chars().count();
    }
    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let b = self.byte_at(self.cursor - 1);
        self.input.remove(b);
        self.cursor -= 1;
    }
    fn delete_at(&mut self) {
        if self.cursor >= self.char_len() {
            return;
        }
        let b = self.byte_at(self.cursor);
        self.input.remove(b);
    }
    fn delete_word_before(&mut self) {
        let b = self.byte_at(self.cursor);
        let head = self.input[..b].trim_end().to_string();
        let cut = head.rfind(' ').map(|i| i + 1).unwrap_or(0);
        let tail = self.input[b..].to_string();
        self.input = format!("{}{}", &head[..cut], tail);
        self.cursor = head[..cut].chars().count();
    }
    fn clear_input(&mut self) {
        self.input.clear();
        self.cursor = 0;
    }
}

fn main() -> io::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste
    )?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    // Restore the terminal even on panic — a raw-mode corpse is the worst UX.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(
            io::stdout(),
            DisableBracketedPaste,
            DisableMouseCapture,
            LeaveAlternateScreen
        );
        default_hook(info);
    }));

    let mut roster = RosterRail::from_doctor();
    let mut messages = widgets::messages::MessageList::from_pad();
    let mut board = widgets::tasks::TaskBoard::from_pad();
    let mut app = App {
        tab: 0,
        input: String::new(),
        cursor: 0,
        detail_open: false,
        watcher_alive: RosterRail::watcher_alive(),
        flash: None,
        msg_inner: Rect::default(),
        tab_hits: [(0, 0); 2],
        drag_anchor: None,
    };

    // Live-tail: watch .stitchpad/ and re-read pad-derived views on change.
    let (watch_tx, watch_rx) = mpsc::channel::<()>();
    let _watcher = {
        let tx = watch_tx.clone();
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if res.is_ok() {
                let _ = tx.send(());
            }
        })
        .and_then(|mut w| {
            // watch the dir (editors/append may replace the inode); filter is cheap.
            w.watch(Path::new(".stitchpad"), RecursiveMode::NonRecursive)?;
            Ok(w)
        })
        .ok()
    };

    // Background roster ticker: doctor + liveness probes are forks — far too slow
    // for the draw loop, and alive.* lives in .state/ where the non-recursive
    // watcher can't see it. A thread re-fetches every 5s and ships results over a
    // channel; the UI just drains. This is what makes the duplicate-member /
    // stale-triangle staleness impossible: the rail ALWAYS converges on doctor.
    let (roster_tx, roster_rx) = mpsc::channel::<(Vec<RosterMember>, bool)>();
    std::thread::spawn(move || {
        loop {
            let members = RosterRail::fetch();
            let alive = RosterRail::watcher_alive();
            if roster_tx.send((members, alive)).is_err() {
                break; // UI gone
            }
            std::thread::sleep(Duration::from_secs(5));
        }
    });

    let pad_name = std::env::current_dir()
        .ok()
        .and_then(|d| d.file_name().map(|f| f.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "pasture".into());

    loop {
        // Drain pad-change events (collapse bursts into one refresh) — every
        // pad-derived view re-reads, not just messages (the old staleness bug).
        let mut changed = false;
        while watch_rx.try_recv().is_ok() {
            changed = true;
        }
        if changed {
            messages.refresh();
            board.refresh();
        }
        // Drain background roster updates.
        while let Ok((members, alive)) = roster_rx.try_recv() {
            roster.set_members(members);
            app.watcher_alive = alive;
        }

        terminal.draw(|f| {
            use ratatui::style::{Color, Modifier, Style};
            use ratatui::text::{Line, Span};
            use ratatui::widgets::{Block, Borders, Paragraph};

            let show_input = app.tab == 0;
            // Input box grows with content (wrapped), 1..=4 text rows + border.
            let input_h = if show_input {
                let inner_w = (f.area().width.saturating_sub(2)).max(8) as usize;
                let rows = (app.char_len() + 1).div_ceil(inner_w).clamp(1, 4) as u16;
                rows + 2
            } else {
                0
            };
            let mut constraints = vec![Constraint::Length(1), Constraint::Min(3)];
            if show_input {
                constraints.push(Constraint::Length(input_h));
            }
            constraints.push(Constraint::Length(1));
            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints(constraints)
                .split(f.area());
            let (header_row, main_row) = (rows[0], rows[1]);
            let input_row = if show_input { Some(rows[2]) } else { None };
            let footer_row = rows[rows.len() - 1];

            // ── Header: pad name · tabs · watcher + agent count ──────────
            let dim = Style::default().fg(Color::Rgb(128, 128, 128));
            let mut header = vec![
                Span::styled(" ⛵ ", Style::default().fg(Color::Cyan)),
                Span::styled(
                    pad_name.clone(),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::raw("   "),
            ];
            // running display column for click hit-testing (" ⛵ " renders 4 cells)
            let mut col: u16 = 4 + pad_name.chars().count() as u16 + 3;
            for (i, label) in ["Chat", "Tasks"].iter().enumerate() {
                let w = label.chars().count() as u16 + 2; // " label "
                app.tab_hits[i] = (col, col + w - 1);
                col += w + 1; // + separator space
                if i as u8 == app.tab {
                    header.push(Span::styled(
                        format!(" {} ", label),
                        Style::default().fg(Color::Black).bg(Color::Cyan),
                    ));
                } else {
                    header.push(Span::styled(format!(" {} ", label), dim));
                }
                header.push(Span::raw(" "));
            }
            let online = roster
                .members
                .iter()
                .filter(|m| {
                    matches!(m.live_status, widgets::roster::LiveStatus::Online)
                })
                .count();
            let dot = if app.watcher_alive { "●" } else { "○" };
            let right_full = format!(
                "{} {} · {}/{} online ",
                dot,
                if app.watcher_alive { "watcher" } else { "watcher DOWN (^S)" },
                online,
                roster.members.len(),
            );
            let right_compact = format!("{} {}/{} ", dot, online, roster.members.len());
            // +1: the ⛵ renders 2 cells but counts as 1 char.
            let left_w = 1 + header
                .iter()
                .map(|s| s.content.chars().count())
                .sum::<usize>();
            let avail = (header_row.width as usize).saturating_sub(left_w);
            // Fit the full status if we can, the compact one if we must.
            let right = if right_full.chars().count() <= avail {
                right_full
            } else if right_compact.chars().count() <= avail {
                right_compact
            } else {
                String::new()
            };
            let pad_w = avail.saturating_sub(right.chars().count());
            header.push(Span::raw(" ".repeat(pad_w)));
            header.push(Span::styled(
                right,
                Style::default().fg(if app.watcher_alive {
                    Color::Green
                } else {
                    Color::Red
                }),
            ));
            f.render_widget(Paragraph::new(Line::from(header)), header_row);

            // ── Main area ────────────────────────────────────────────────
            if app.tab == 1 {
                f.render_widget(&board, main_row);
                if app.detail_open {
                    if let Some(task) = board.selected_task() {
                        widgets::tasks::render_detail(task, f.area(), f.buffer_mut());
                    }
                }
            } else {
                // Floor plan: below 90 cols the agents rail folds away and the
                // conversation takes the full width (still fine at 80×24).
                let msg_rect = if main_row.width >= 90 {
                    let cols = Layout::default()
                        .direction(Direction::Horizontal)
                        .constraints([Constraint::Min(40), Constraint::Length(26)])
                        .split(main_row);
                    f.render_widget(&messages, cols[0]);
                    f.render_widget(&roster, cols[1]);
                    cols[0]
                } else {
                    f.render_widget(&messages, main_row);
                    main_row
                };
                // inner rect (inside the border) for mouse hit-testing
                app.msg_inner = Rect {
                    x: msg_rect.x + 1,
                    y: msg_rect.y + 1,
                    width: msg_rect.width.saturating_sub(2),
                    height: msg_rect.height.saturating_sub(2),
                };

                // ── Prompt: ALWAYS live. Type → Enter sends. ────────────
                if let Some(area) = input_row {
                    let me = std::env::var("STITCHPAD_NAME").unwrap_or_else(|_| "smaths".into());
                    let border = if app.input.is_empty() {
                        Style::default().fg(Color::Rgb(90, 90, 90))
                    } else {
                        Style::default().fg(Color::Cyan)
                    };
                    let content: Line = if app.input.is_empty() {
                        Line::from(Span::styled(
                            "type to talk · @name wakes them · Enter sends",
                            dim,
                        ))
                    } else {
                        // cursor-split render: text before · cursor cell · text after
                        let b = app.byte_at(app.cursor);
                        let before = app.input[..b].to_string();
                        let mut rest = app.input[b..].chars();
                        let under = rest.next();
                        let after: String = rest.collect();
                        let mut spans = vec![Span::raw(before)];
                        match under {
                            Some(c) => spans.push(Span::styled(
                                c.to_string(),
                                Style::default().add_modifier(Modifier::REVERSED),
                            )),
                            None => spans.push(Span::styled(
                                "█",
                                Style::default().fg(Color::Cyan),
                            )),
                        }
                        spans.push(Span::raw(after));
                        Line::from(spans)
                    };
                    f.render_widget(
                        Paragraph::new(content)
                            .wrap(ratatui::widgets::Wrap { trim: false })
                            .block(
                                Block::default()
                                    .borders(Borders::ALL)
                                    .border_style(border)
                                    .title(format!(" @{} ", me)),
                            ),
                        area,
                    );
                }
            }

            // ── Footer: flash message wins, else per-tab hints ───────────
            let footer_text = if let Some(fmsg) = app.flash_line() {
                fmsg.to_string()
            } else if app.tab == 1 {
                "j/k:nav  Enter:detail  ]/[:move  d:done  x:cancel  1/^T:chat  q:quit".to_string()
            } else {
                "Enter:send  Tab:@complete  drag:copy sel  ^Y:copy convo  wheel/↑↓:scroll  ^T:tasks  ^C:quit"
                    .to_string()
            };
            f.render_widget(Paragraph::new(footer_text).style(dim), footer_row);
        })?;

        // ── Input ────────────────────────────────────────────────────────
        if event::poll(Duration::from_millis(100))? {
            match event::read()? {
                Event::Mouse(me) => {
                    let inside_msgs = app.tab == 0
                        && me.column >= app.msg_inner.x
                        && me.column < app.msg_inner.x + app.msg_inner.width
                        && me.row >= app.msg_inner.y
                        && me.row < app.msg_inner.y + app.msg_inner.height;
                    match me.kind {
                        MouseEventKind::ScrollUp => {
                            if app.tab == 0 {
                                messages.scroll_up();
                            } else {
                                board.previous();
                            }
                        }
                        MouseEventKind::ScrollDown => {
                            if app.tab == 0 {
                                messages.scroll_down();
                            } else {
                                board.next();
                            }
                        }
                        MouseEventKind::Down(MouseButton::Left) => {
                            if me.row == 0 {
                                // header tab click
                                for (i, (x0, x1)) in app.tab_hits.iter().enumerate() {
                                    if me.column >= *x0 && me.column <= *x1 {
                                        app.tab = i as u8;
                                        app.detail_open = false;
                                    }
                                }
                            } else if inside_msgs {
                                // start a drag-selection at this visible row
                                let row = me.row - app.msg_inner.y;
                                app.drag_anchor = Some(row);
                                messages.selection = Some((row, row));
                            } else {
                                app.drag_anchor = None;
                                messages.selection = None;
                            }
                        }
                        MouseEventKind::Drag(MouseButton::Left) => {
                            if let Some(anchor) = app.drag_anchor {
                                if app.tab == 0 && app.msg_inner.height > 0 {
                                    let row = me
                                        .row
                                        .clamp(
                                            app.msg_inner.y,
                                            app.msg_inner.y + app.msg_inner.height - 1,
                                        )
                                        - app.msg_inner.y;
                                    messages.selection = Some((anchor, row));
                                }
                            }
                        }
                        MouseEventKind::Up(MouseButton::Left) => {
                            if let (Some(_), Some((a, b))) =
                                (app.drag_anchor.take(), messages.selection)
                            {
                                // a plain click (no movement) just clears; a real drag copies
                                if a != b {
                                    let text = messages.selected_text(
                                        app.msg_inner.width,
                                        app.msg_inner.height,
                                        a,
                                        b,
                                    );
                                    match copy_text(&text) {
                                        Ok(()) => app.flash(format!(
                                            "copied {} lines to clipboard",
                                            a.abs_diff(b) + 1
                                        )),
                                        Err(e) => app.flash(format!("copy failed: {}", e)),
                                    }
                                }
                                messages.selection = None;
                            }
                        }
                        _ => {}
                    }
                }
                Event::Key(key) => {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);

                // Global (both tabs): modifier chords.
                if ctrl {
                    match key.code {
                        KeyCode::Char('c') => break,
                        KeyCode::Char('t') => {
                            app.tab ^= 1;
                            app.detail_open = false;
                            continue;
                        }
                        KeyCode::Char('r') => {
                            color::invalidate();
                            roster.refresh();
                            messages.refresh();
                            board.refresh();
                            app.watcher_alive = RosterRail::watcher_alive();
                            app.flash("refreshed");
                            continue;
                        }
                        KeyCode::Char('y') => {
                            match copy_conversation(&messages) {
                                Ok(n) => app.flash(format!("copied {} messages to clipboard", n)),
                                Err(e) => app.flash(format!("copy failed: {}", e)),
                            }
                            continue;
                        }
                        KeyCode::Char('s') => {
                            let _ = std::process::Command::new("stitchpad")
                                .arg("restart")
                                .output();
                            app.watcher_alive = RosterRail::watcher_alive();
                            app.flash("watcher restarted");
                            continue;
                        }
                        KeyCode::Char('u') => {
                            app.clear_input();
                            continue;
                        }
                        KeyCode::Char('w') => {
                            app.delete_word_before(); // readline convention
                            continue;
                        }
                        KeyCode::Char('a') => {
                            app.cursor = 0;
                            continue;
                        }
                        KeyCode::Char('e') => {
                            app.cursor = app.char_len();
                            continue;
                        }
                        _ => {}
                    }
                }

                if app.tab == 1 {
                    // Tasks tab: no text input → plain vim keys.
                    match key.code {
                        KeyCode::Char('q') => break,
                        KeyCode::Esc => {
                            if app.detail_open {
                                app.detail_open = false;
                            } else {
                                app.tab = 0;
                            }
                        }
                        KeyCode::Char('t') | KeyCode::Char('1') => {
                            app.tab = 0;
                            app.detail_open = false;
                        }
                        KeyCode::Char('j') | KeyCode::Down => board.next(),
                        KeyCode::Char('k') | KeyCode::Up => board.previous(),
                        KeyCode::Enter => app.detail_open = !app.detail_open,
                        KeyCode::Char(']') => board.move_selected(true),
                        KeyCode::Char('[') => board.move_selected(false),
                        KeyCode::Char('d') => board.set_selected_status("done"),
                        KeyCode::Char('x') => board.set_selected_status("canceled"),
                        KeyCode::Char('r') => board.refresh(),
                        _ => {}
                    }
                    continue;
                }

                // Chat tab: everything printable belongs to the prompt.
                match key.code {
                    KeyCode::Enter => {
                        let text = app.input.trim().to_string();
                        if !text.is_empty() {
                            let ok = std::process::Command::new("stitchpad")
                                .arg("say")
                                .arg(&text)
                                .output()
                                .map(|o| o.status.success())
                                .unwrap_or(false);
                            if ok {
                                app.clear_input();
                                messages.refresh();
                            } else {
                                app.flash("send failed — is this a pad dir?");
                            }
                        }
                    }
                    KeyCode::Esc => app.clear_input(),
                    KeyCode::Backspace => app.backspace(),
                    KeyCode::Delete => app.delete_at(),
                    KeyCode::Left => app.cursor = app.cursor.saturating_sub(1),
                    KeyCode::Right => app.cursor = (app.cursor + 1).min(app.char_len()),
                    KeyCode::Home => app.cursor = 0,
                    KeyCode::End => app.cursor = app.char_len(),
                    KeyCode::Tab => {
                        // @name completion (only when the cursor sits at the end,
                        // where the @-token being typed lives).
                        if app.cursor == app.char_len() {
                            if let Some(done) = complete_mention(&app.input, &roster.members)
                            {
                                app.input = done;
                                app.cursor = app.char_len();
                            }
                        }
                    }
                    KeyCode::Up | KeyCode::PageUp => {
                        let n = if key.code == KeyCode::PageUp { 10 } else { 1 };
                        for _ in 0..n {
                            messages.scroll_up();
                        }
                    }
                    KeyCode::Down | KeyCode::PageDown => {
                        let n = if key.code == KeyCode::PageDown { 10 } else { 1 };
                        for _ in 0..n {
                            messages.scroll_down();
                        }
                    }
                    KeyCode::Char(c) => app.insert_str(&c.to_string()),
                    _ => {}
                }
                }
                Event::Paste(s) => {
                    // Bracketed paste: land the WHOLE paste in the input as one
                    // unit — without this, a newline in pasted text acts as Enter
                    // and fires partial messages mid-paste.
                    if app.tab == 0 {
                        let clean = s.replace('\r', "\n");
                        app.insert_str(&clean);
                    }
                }
                _ => {}
            }
        }
    }

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        DisableBracketedPaste,
        DisableMouseCapture,
        LeaveAlternateScreen
    )?;
    terminal.show_cursor()?;
    Ok(())
}

/// Complete the trailing `@prefix` token against roster names. Returns the new
/// input line, or None if the cursor isn't on an @-token / nothing matches.
fn complete_mention(input: &str, members: &[RosterMember]) -> Option<String> {
    let start = input.rfind('@')?;
    // the @ must start a token (line start or after whitespace)
    if start > 0 && !input[..start].ends_with(' ') {
        return None;
    }
    let prefix = &input[start + 1..];
    if prefix.contains(' ') {
        return None; // cursor is past the token
    }
    let m = members
        .iter()
        .find(|m| m.name.starts_with(prefix) && m.name != prefix)?;
    Some(format!("{}@{} ", &input[..start], m.name))
}

/// Copy the visible conversation to the system clipboard as clean markdown —
/// no gutters, borders, or roster bleed (the reason terminal drag-select is
/// useless in a multi-panel TUI). macOS pbcopy; xclip/wl-copy fallbacks.
fn copy_conversation(list: &widgets::messages::MessageList) -> Result<usize, String> {
    let mut out = String::new();
    for m in &list.messages {
        out.push_str(&format!("@{} · {}\n", m.author, m.time));
        for line in &m.body {
            out.push_str(line);
            out.push('\n');
        }
        out.push('\n');
    }
    if out.is_empty() {
        return Err("no messages".into());
    }
    copy_text(&out)?;
    Ok(list.messages.len())
}

/// Pipe text to the system clipboard (pbcopy on macOS; wl-copy/xclip fallbacks).
fn copy_text(text: &str) -> Result<(), String> {
    let candidates: &[(&str, &[&str])] = &[
        ("pbcopy", &[]),
        ("wl-copy", &[]),
        ("xclip", &["-selection", "clipboard"]),
    ];
    for (cmd, args) in candidates {
        let child = std::process::Command::new(cmd)
            .args(*args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        if let Ok(mut child) = child {
            if let Some(stdin) = child.stdin.as_mut() {
                if stdin.write_all(text.as_bytes()).is_ok() {
                    let _ = child.wait();
                    return Ok(());
                }
            }
            let _ = child.wait();
        }
    }
    Err("no clipboard tool (pbcopy/wl-copy/xclip)".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use widgets::roster::{Health, LiveStatus};

    fn member(name: &str) -> RosterMember {
        RosterMember {
            name: name.into(),
            adapter: "pi".into(),
            wake: "push".into(),
            harness: "pi".into(),
            model: "—".into(),
            health: Health::Healthy,
            live_status: LiveStatus::Online,
            issue: None,
        }
    }

    #[test]
    fn completes_mention_prefix() {
        let members = vec![member("codex"), member("fable")];
        assert_eq!(
            complete_mention("@co", &members).as_deref(),
            Some("@codex ")
        );
        assert_eq!(
            complete_mention("hey @fa", &members).as_deref(),
            Some("hey @fable ")
        );
        // mid-word @ (email-ish) must not complete
        assert_eq!(complete_mention("me@co", &members), None);
        // past the token → no completion
        assert_eq!(complete_mention("@codex hi", &members), None);
        // no match
        assert_eq!(complete_mention("@zz", &members), None);
    }
}
