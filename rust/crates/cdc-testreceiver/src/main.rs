//! Uso: cdc-testreceiver HOST:PORTA [--seconds N] [--v4l2 /dev/videoN] [--dump arquivo.h264] [--quiet]

use std::net::TcpStream;
use std::process::ExitCode;
use std::time::Duration;

use cdc_testreceiver::{Options, Sink, run};

const USO: &str = "uso: cdc-testreceiver HOST:PORTA [--seconds N] [--v4l2 DISPOSITIVO] [--dump ARQUIVO] [--quiet]";

fn main() -> ExitCode {
    let mut address = None;
    let mut options = Options {
        duration: None,
        sink: Sink::default(),
        ffmpeg: "ffmpeg".into(),
        verbose: true,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or(format!("{name} precisa de um valor"));
        let parsed: Result<(), String> = match arg.as_str() {
            "--seconds" => value("--seconds").and_then(|v| {
                v.parse::<u64>()
                    .map(|s| options.duration = Some(Duration::from_secs(s)))
                    .map_err(|_| "segundos inválidos".into())
            }),
            "--v4l2" => value("--v4l2").map(|v| options.sink.v4l2 = Some(v)),
            "--dump" => value("--dump").map(|v| options.sink.dump = Some(v)),
            "--quiet" => {
                options.verbose = false;
                Ok(())
            }
            other if !other.starts_with("--") && address.is_none() => {
                address = Some(other.to_string());
                Ok(())
            }
            other => Err(format!("argumento desconhecido: {other}")),
        };
        if let Err(msg) = parsed {
            eprintln!("erro: {msg}\n{USO}");
            return ExitCode::from(2);
        }
    }
    let Some(address) = address else {
        eprintln!("{USO}");
        return ExitCode::from(2);
    };

    eprintln!("conectando a {address}...");
    let stream = match TcpStream::connect(&address) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("erro ao conectar: {e}");
            return ExitCode::FAILURE;
        }
    };
    match run(stream, &options) {
        Ok(report) => {
            eprintln!(
                "\nresumo: {} frames de vídeo ({} keyframes) em {:.1} s\n  média {:.1} FPS, {:.0} kb/s, maior intervalo entre frames {:.0} ms",
                report.video_frames,
                report.keyframes,
                report.seconds,
                report.avg_fps,
                report.avg_kbps,
                report.max_gap_ms
            );
            if report.video_frames == 0 {
                eprintln!("nenhum frame de vídeo recebido");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("erro: {e}");
            ExitCode::FAILURE
        }
    }
}
