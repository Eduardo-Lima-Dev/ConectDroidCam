//! Liga o receptor ao emissor simulado e confere o relatório. Pula sem ffmpeg.

use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::thread;

use cdc_core::{SessionOptions, Sink, StopHandle, run};
use cdc_protocol::VideoProfile;
use cdc_testsender::{Options as SenderOptions, serve_connection};

fn ffmpeg_disponivel() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[test]
fn receptor_mede_o_fluxo_e_grava_h264_valido() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let porta = listener.local_addr().unwrap().port();
    let servidor = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let opcoes = SenderOptions::new(VideoProfile::Hd, 2);
        serve_connection(stream, &opcoes)
    });

    let arquivo = std::env::temp_dir().join(format!("cdc-teste-{porta}.h264"));
    let opcoes = SessionOptions {
        sink: Sink {
            v4l2: None,
            dump: Some(arquivo.to_string_lossy().into_owned()),
        },
        ..SessionOptions::default()
    };
    let stream = TcpStream::connect(("127.0.0.1", porta)).unwrap();
    let relatorio = run(stream, &opcoes, &StopHandle::new(), |_| {}).unwrap();
    let _ = servidor.join();

    assert_eq!(relatorio.actual, Some((1280, 720, 30)));
    assert!(relatorio.received_config);
    assert!(
        (50..=65).contains(&relatorio.video_frames),
        "frames: {}",
        relatorio.video_frames
    );
    assert!(relatorio.keyframes >= 2);
    assert!(
        (25.0..=32.0).contains(&relatorio.avg_fps),
        "fps médio: {}",
        relatorio.avg_fps
    );

    // O arquivo gravado precisa ser um H.264 que o ffprobe entende, com a resolução certa.
    let saida = Command::new("ffprobe")
        .args(["-v", "error", "-select_streams", "v:0"])
        .args(["-show_entries", "stream=width,height", "-of", "csv=p=0"])
        .arg(&arquivo)
        .output();
    let _ = std::fs::remove_file(&arquivo);
    if let Ok(saida) = saida {
        assert_eq!(String::from_utf8_lossy(&saida.stdout).trim(), "1280,720");
    }
}
