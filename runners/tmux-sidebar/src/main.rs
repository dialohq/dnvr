use std::{
    env,
    error::Error,
    io::{self, Stdout},
    process::{Command, Output},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use crossterm::{
    cursor::{Hide, Show},
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind,
        KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
    },
    execute,
    style::Colored,
    terminal::{disable_raw_mode, enable_raw_mode},
};
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Cell, Paragraph, Row, Table},
};
use signal_hook::consts::signal::SIGUSR1;
use unicode_width::UnicodeWidthChar;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const INPUT_POLL: Duration = Duration::from_millis(100);
const RESIZE_SETTLE: Duration = Duration::from_millis(16);

fn fit_to_width(text: &str, width: usize) -> String {
    let mut rendered = String::new();
    let mut used = 0;
    for character in text.chars() {
        let character_width = character.width().unwrap_or(0);
        if used + character_width > width {
            break;
        }
        rendered.push(character);
        used += character_width;
    }
    rendered.extend(std::iter::repeat_n(' ', width.saturating_sub(used)));
    rendered
}

#[derive(Clone)]
struct Process {
    index: usize,
    pane: String,
    name: String,
    dead: bool,
}

fn process_row(process: &Process, marker: &str, selected: bool, name_width: usize) -> Row<'static> {
    let selected_style = if selected {
        Style::default().add_modifier(Modifier::REVERSED)
    } else {
        Style::default()
    };
    let (status, mut status_style) = if process.dead {
        ("DOWN", Style::default().fg(Color::LightRed))
    } else {
        ("UP", Style::default().fg(Color::LightGreen))
    };
    if selected {
        status_style = status_style.add_modifier(Modifier::REVERSED);
    }
    Row::new([
        Cell::from(Span::styled(format!("{marker} "), selected_style)),
        Cell::from(Span::styled(
            fit_to_width(&process.name, name_width),
            selected_style,
        )),
        Cell::from(Span::styled(format!(" {status:>4}"), status_style)),
    ])
}

struct App {
    sidebar_pane: String,
    session_id: String,
    processes: Vec<Process>,
    selected: usize,
    viewport_offset: usize,
    viewport_height: usize,
}

impl App {
    fn new() -> Result<Self> {
        let sidebar_pane = env::var("TMUX_PANE")?;
        let session_id = tmux_text(&[
            "display-message",
            "-p",
            "-t",
            &sidebar_pane,
            "#{session_id}",
        ])?;
        let mut app = Self {
            sidebar_pane,
            session_id,
            processes: Vec::new(),
            selected: 0,
            viewport_offset: 0,
            viewport_height: 0,
        };
        app.reload()?;
        Ok(app)
    }

    fn reload(&mut self) -> Result<()> {
        let output = tmux_text(&[
            "list-panes",
            "-s",
            "-t",
            &self.session_id,
            "-F",
            "#{@dnvr_index}\t#{pane_id}\t#{@dnvr_name}\t#{pane_dead}",
        ])?;
        let mut processes = output
            .lines()
            .filter_map(|line| {
                let mut fields = line.splitn(4, '\t');
                Some(Process {
                    index: fields.next()?.parse().ok()?,
                    pane: fields.next()?.to_owned(),
                    name: fields.next()?.to_owned(),
                    dead: fields.next()? == "1",
                })
            })
            .collect::<Vec<_>>();
        processes.sort_by_key(|process| process.index);
        self.processes = processes;
        self.selected = self.selected.min(self.processes.len().saturating_sub(1));
        Ok(())
    }

    fn selected_pane(&self) -> Option<&str> {
        self.processes
            .get(self.selected)
            .map(|process| process.pane.as_str())
    }

    fn visible_pane(&self) -> Result<Option<String>> {
        let output = tmux_text(&[
            "list-panes",
            "-t",
            &self.sidebar_pane,
            "-F",
            "#{?#{==:#{@dnvr_role},process},#{pane_id},}",
        ])?;
        Ok(output
            .lines()
            .find(|line| !line.is_empty())
            .map(str::to_owned))
    }

    fn process_active(&self, pane: Option<&str>) -> Result<bool> {
        let Some(pane) = pane else { return Ok(false) };
        Ok(tmux_text(&["display-message", "-p", "-t", pane, "#{pane_active}"])? == "1")
    }

    fn show_selected(&self, focus: bool) -> Result<()> {
        let Some(target) = self.selected_pane() else {
            return Ok(());
        };
        let current = self.visible_pane()?;
        if current.as_deref() != Some(target) {
            if let Some(current) = current {
                tmux(&["swap-pane", "-d", "-s", target, "-t", &current])?;
            } else {
                tmux(&["join-pane", "-h", "-s", target, "-t", &self.sidebar_pane])?;
                tmux(&["select-layout", "-t", &self.sidebar_pane, "main-vertical"])?;
            }
        }
        if focus {
            tmux(&["select-pane", "-t", target])?;
        }
        Ok(())
    }

    fn activate_selected(&self) -> Result<()> {
        let Some(target) = self.selected_pane() else {
            return Ok(());
        };
        if self.visible_pane()?.as_deref() == Some(target) {
            tmux(&["select-pane", "-t", target])?;
        } else {
            self.show_selected(false)?;
        }
        Ok(())
    }

    fn move_selection(&mut self, delta: isize) {
        let count = self.processes.len();
        if count > 0 {
            self.selected = (self.selected as isize + delta).rem_euclid(count as isize) as usize;
        }
    }

    fn click(&mut self, mouse: MouseEvent) -> Result<bool> {
        if mouse.kind != MouseEventKind::Down(MouseButton::Left) {
            return Ok(false);
        }
        let row = mouse.row as usize;
        let index = self.viewport_offset + row;
        if row < self.viewport_height && index < self.processes.len() {
            self.selected = index;
            self.show_selected(false)?;
            return Ok(true);
        }
        Ok(false)
    }

    fn handle_key(&mut self, key: KeyEvent) -> Result<bool> {
        if key.kind != KeyEventKind::Press {
            return Ok(false);
        }
        match (key.code, key.modifiers) {
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => self.move_selection(1),
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => self.move_selection(-1),
            (KeyCode::Enter, _) => self.activate_selected()?,
            (KeyCode::Char('r'), KeyModifiers::NONE) => {
                if let Some(pane) = self.selected_pane() {
                    tmux(&["respawn-pane", "-k", "-t", pane])?;
                }
                self.reload()?;
            }
            (KeyCode::Char('x'), KeyModifiers::NONE) => {
                if let Some(pane) = self.selected_pane() {
                    tmux(&["send-keys", "-t", pane, "C-c"])?;
                }
            }
            (KeyCode::Char('Q'), KeyModifiers::SHIFT) => {
                tmux(&["kill-session", "-t", &self.session_id])?;
            }
            _ => return Ok(false),
        }
        Ok(true)
    }

    fn draw(&mut self, terminal: &mut Terminal<CrosstermBackend<Stdout>>) -> Result<()> {
        let visible = self.visible_pane()?;
        let process_active = self.process_active(visible.as_deref())?;
        let mut viewport_offset = self.viewport_offset;
        let mut viewport_height = self.viewport_height;
        terminal.draw(|frame| {
            let [process_area, footer_area] =
                Layout::vertical([Constraint::Min(0), Constraint::Length(4)]).areas(frame.area());

            let visible_rows = process_area.height as usize;
            viewport_height = visible_rows;
            let max_offset = self.processes.len().saturating_sub(visible_rows);
            let name_width = process_area.width.saturating_sub(7) as usize;
            viewport_offset = viewport_offset.min(max_offset);
            if self.selected < viewport_offset {
                viewport_offset = self.selected;
            } else if visible_rows > 0 && self.selected >= viewport_offset + visible_rows {
                viewport_offset = self.selected + 1 - visible_rows;
            }

            let rows = self
                .processes
                .iter()
                .enumerate()
                .skip(viewport_offset)
                .take(visible_rows)
                .map(|(index, process)| {
                    let marker = if visible.as_deref() == Some(process.pane.as_str()) {
                        if process_active { "▶" } else { "●" }
                    } else {
                        " "
                    };
                    process_row(process, marker, index == self.selected, name_width)
                });
            let table = Table::new(
                rows,
                [
                    Constraint::Length(2),
                    Constraint::Fill(1),
                    Constraint::Length(5),
                ],
            )
            .column_spacing(0);
            frame.render_widget(table, process_area);

            let hint = if process_active {
                "process active  C-a sidebar"
            } else if self.selected_pane() == visible.as_deref() {
                "j/k move    enter interact"
            } else {
                "j/k move    enter view"
            };
            let footer_style = Style::default().fg(Color::DarkGray);
            let footer = Paragraph::new(vec![
                Line::styled(hint, footer_style),
                Line::styled(" r restart   x interrupt", footer_style),
                Line::styled(" C-a sidebar C-g detach", footer_style),
                Line::styled(" Q stop all", footer_style),
            ]);
            frame.render_widget(footer, footer_area);
        })?;
        self.viewport_offset = viewport_offset;
        self.viewport_height = viewport_height;
        Ok(())
    }
}

struct TerminalRestore;

impl Drop for TerminalRestore {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), DisableMouseCapture, Show);
    }
}

fn tmux(args: &[&str]) -> Result<Output> {
    let output = Command::new("tmux").args(args).output()?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(format!(
            "tmux {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into())
    }
}

fn tmux_text(args: &[&str]) -> Result<String> {
    Ok(String::from_utf8(tmux(args)?.stdout)?.trim_end().to_owned())
}

fn main() -> Result<()> {
    // tmux's dashboard uses colors regardless of NO_COLOR. Crossterm's
    // NO_COLOR path also turns SetColors into an empty SGR sequence, which
    // resets unrelated modifiers such as the selected row's reverse style.
    Colored::set_ansi_color_disabled(false);

    let refresh = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(SIGUSR1, Arc::clone(&refresh))?;

    let mut app = App::new()?;
    tmux(&[
        "set-option",
        "-p",
        "-t",
        &app.sidebar_pane,
        "@dnvr_sidebar_pid",
        &std::process::id().to_string(),
    ])?;

    enable_raw_mode()?;
    execute!(io::stdout(), EnableMouseCapture, Hide)?;
    let _restore = TerminalRestore;
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    terminal.clear()?;
    app.draw(&mut terminal)?;
    tmux(&[
        "set-option",
        "-p",
        "-t",
        &app.sidebar_pane,
        "@dnvr_ready",
        "1",
    ])?;

    let mut redraw_pending = false;
    let mut resize_pending = None;
    let mut rendered_width = terminal.size()?.width;
    loop {
        if refresh.swap(false, Ordering::Relaxed) {
            app.reload()?;
            redraw_pending = true;
        }
        let poll_timeout = resize_pending
            .map(|started: Instant| RESIZE_SETTLE.saturating_sub(started.elapsed()))
            .unwrap_or(INPUT_POLL);
        if event::poll(poll_timeout)? {
            match event::read()? {
                Event::Key(key) => redraw_pending |= app.handle_key(key)?,
                Event::Mouse(mouse) => redraw_pending |= app.click(mouse)?,
                Event::Resize(width, _) if width == rendered_width => {
                    // A width-changing window resize briefly stretches this
                    // pane before the tmux hook restores its fixed width. Do
                    // not paint that intermediate geometry; the restored
                    // width arrives as the next event. Height-only resizes
                    // still redraw immediately.
                    resize_pending = None;
                    terminal.autoresize()?;
                    redraw_pending = true;
                }
                Event::Resize(_, _) => {
                    resize_pending = Some(Instant::now());
                }
                _ => {}
            }
        }
        if resize_pending.is_some_and(|started| started.elapsed() >= RESIZE_SETTLE) {
            // If tmux cannot restore the requested width (for example in a
            // very narrow terminal), render the actual size after one frame.
            resize_pending = None;
            terminal.autoresize()?;
            redraw_pending = true;
        }
        if redraw_pending && resize_pending.is_none() {
            app.draw(&mut terminal)?;
            rendered_width = terminal.size()?.width;
            redraw_pending = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    #[test]
    fn selected_table_row_styles_all_thirty_columns() {
        let backend = TestBackend::new(30, 1);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| {
                let process = Process {
                    index: 0,
                    pane: "%1".to_owned(),
                    name: "clock".to_owned(),
                    dead: false,
                };
                let rows = [process_row(&process, "●", true, 23)];
                let table = Table::new(
                    rows,
                    [
                        Constraint::Length(2),
                        Constraint::Fill(1),
                        Constraint::Length(5),
                    ],
                )
                .column_spacing(0);
                frame.render_widget(table, frame.area());
            })
            .unwrap();

        let buffer = terminal.backend().buffer();
        for x in 0..30 {
            assert!(
                buffer[(x, 0)].modifier.contains(Modifier::REVERSED),
                "column {x} is not selected"
            );
        }
        assert_eq!(buffer[(29, 0)].fg, Color::LightGreen);
    }
}
