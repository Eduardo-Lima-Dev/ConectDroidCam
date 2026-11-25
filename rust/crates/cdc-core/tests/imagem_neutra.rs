#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use cdc_core::{DISCARD, IdleFeed};

fn ffmpeg_disponivel() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[test]
fn imagem_neutra_continua_rodando_ate_ser_parada() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let mut feed = IdleFeed::start("ffmpeg", DISCARD, 1280, 720).unwrap();
    thread::sleep(Duration::from_millis(1200));
    assert!(feed.is_running(), "o ffmpeg parou sozinho");

    let inicio = Instant::now();
    feed.stop();
    assert!(
        inicio.elapsed() < Duration::from_secs(3),
        "parar demorou {:?}",
        inicio.elapsed()
    );
}

#[test]
fn sem_ffmpeg_explica_o_erro() {
    let erro = IdleFeed::start("ffmpeg-que-nao-existe", DISCARD, 640, 360)
        .err()
        .expect("deveria falhar");
    assert!(erro.to_string().contains("ffmpeg"), "{erro}");
}
