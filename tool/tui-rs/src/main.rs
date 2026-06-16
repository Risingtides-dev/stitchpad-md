mod color;
mod widgets;

use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use notify::{RecursiveMode, Watcher};
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
};
use std::io;
use std::path::Path;
use std::sync::mpsc;

fn main() -> io::Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Create roster rail + message list
    let mut roster = widgets::roster::RosterRail::from_doctor();
    let mut messages = widgets::messages::MessageList::from_pad();

    // Compose mode state (wires 'a' compose key; @mark builds the compose widget)
    let mut composing = false;
    let mut compose_buf = String::new();
    let mut focus: u8 = 0; // 0=roster, 1=messages, 2=compose
    let focus_labels = ["roster", "messages", "compose"];

    // Live-tail: watch .stitchpad/stitchpad.md and signal the loop to re-read on change.
    // notify runs its own thread; we only poll the channel non-blockingly below.
    let (watch_tx, watch_rx) = mpsc::channel::<()>();
    let _watcher = {
        let pad = Path::new(".stitchpad/stitchpad.md").to_path_buf();
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
        .map(|w| {
            let _ = &pad;
            w
        }) // keep watcher alive for the program's lifetime
    };

    loop {
        // Live-tail: if the pad changed since last frame, re-read it. Drain all
        // pending events so a burst of writes collapses into one refresh.
        let mut changed = false;
        while watch_rx.try_recv().is_ok() {
            changed = true;
        }
        if changed {
            messages.refresh();
        }

        // Draw UI
        terminal.draw(|f| {
            use ratatui::style::{Color, Style};
            use ratatui::widgets::{Block, Borders, Paragraph};

            // top = main area, bottom = thin hint footer
            let main_chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(3), Constraint::Length(1)])
                .split(f.area());

            // left = messages, right = roster column (rail + compose box stacked)
            let chunks = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(70), Constraint::Percentage(30)])
                .split(main_chunks[0]);

            // right column: roster on top, PROMPT box pinned to the bottom.
            let right = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(10), Constraint::Length(8)])
                .split(chunks[1]);

            // Message list (live-tail, scrollable)
            f.render_widget(&messages, chunks[0]);
            // Roster rail
            f.render_widget(&roster, right[0]);

            // Prompt box — under the roster. Type @names to address agents, Enter sends.
            let (title, body, border) = if composing {
                (
                    " Prompt  Enter=send  Esc=cancel ",
                    format!("{}\n_", compose_buf),
                    Color::Cyan,
                )
            } else {
                (
                    " Prompt ",
                    "Press a to compose\nStart with @name to wake agents\n\n".to_string(),
                    Color::DarkGray,
                )
            };
            let compose = Paragraph::new(body)
                .style(Style::default().fg(if composing { Color::White } else { Color::Gray }))
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .title(title)
                        .border_style(Style::default().fg(border)),
                )
                .wrap(ratatui::widgets::Wrap { trim: false });
            f.render_widget(compose, right[1]);

            // thin bottom hint
            let footer = Paragraph::new(format!(
                "q:quit  a:compose  Tab:focus[{}]  j/k:nav  r:refresh",
                focus_labels[focus as usize]
            ));
            f.render_widget(footer, main_chunks[1]);
        })?;

        // Handle input
        if event::poll(std::time::Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    if composing {
                        match key.code {
                            KeyCode::Esc => {
                                composing = false;
                                compose_buf.clear();
                            }
                            KeyCode::Enter => {
                                if !compose_buf.trim().is_empty() {
                                    // Shell out to stitchpad say; STITCHPAD_NAME comes from env
                                    let _ = std::process::Command::new("stitchpad")
                                        .arg("say")
                                        .arg(&compose_buf)
                                        .status();
                                    compose_buf.clear();
                                    composing = false;
                                    messages.refresh();
                                }
                            }
                            KeyCode::Backspace => {
                                compose_buf.pop();
                            }
                            KeyCode::Char(c) => compose_buf.push(c),
                            _ => {}
                        }
                    } else {
                        match key.code {
                            KeyCode::Char('q') => break,
                            KeyCode::Char('a') => {
                                composing = true;
                                compose_buf.clear();
                            }
                            KeyCode::Tab => focus = (focus + 1) % focus_labels.len() as u8,
                            KeyCode::BackTab => {
                                focus = (focus + focus_labels.len() as u8 - 1)
                                    % focus_labels.len() as u8
                            }
                            KeyCode::Char('j') => {
                                if focus == 0 {
                                    roster.next()
                                } else {
                                    messages.scroll_down()
                                }
                            }
                            KeyCode::Char('k') => {
                                if focus == 0 {
                                    roster.previous()
                                } else {
                                    messages.scroll_up()
                                }
                            }
                            KeyCode::Up => messages.scroll_up(),
                            KeyCode::Down => messages.scroll_down(),
                            KeyCode::PageUp => {
                                for _ in 0..10 {
                                    messages.scroll_up()
                                }
                            }
                            KeyCode::PageDown => {
                                for _ in 0..10 {
                                    messages.scroll_down()
                                }
                            }
                            KeyCode::Char('r') => {
                                color::invalidate();
                                roster.refresh();
                                messages.refresh();
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    Ok(())
}
