use std::env;

fn main() -> dnvr_tmux_sidebar::Result<()> {
    dnvr_tmux_sidebar::state::run_standalone(env::args_os().skip(1))
}
