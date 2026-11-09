//! Uso: cdc-testsender [--bind 127.0.0.1] [--port 47821] [--profile hd|fullhd|qhd] [--seconds 10]

use std::net::TcpListener;
use std::process::ExitCode;

use cdc_protocol::VideoProfile;
use cdc_testsender::{Options, serve_connection};

struct Args {
    bind: String,
    port: u16,
    profile: VideoProfile,
    seconds: u32,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        bind: "127.0.0.1".into(),
        port: 47821,
        profile: VideoProfile::Hd,
        seconds: 10,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = |name: &str| it.next().ok_or(format!("{name} precisa de um valor"));
        match flag.as_str() {
            "--bind" => args.bind = value("--bind")?,
            "--port" => {
                args.port = value("--port")?
                    .parse()
                    .map_err(|_| "porta inválida".to_string())?;
            }
            "--seconds" => {
                args.seconds = value("--seconds")?
                    .parse()
                    .map_err(|_| "segundos inválidos".to_string())?;
            }
            "--profile" => {
                args.profile = match value("--profile")?.as_str() {
                    "hd" => VideoProfile::Hd,
                    "fullhd" => VideoProfile::FullHd,
                    "qhd" => VideoProfile::Qhd,
                    outro => return Err(format!("perfil desconhecido: {outro}")),
                };
            }
            outro => return Err(format!("argumento desconhecido: {outro}")),
        }
    }
    Ok(args)
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(args) => args,
        Err(msg) => {
            eprintln!(
                "erro: {msg}\nuso: cdc-testsender [--bind IP] [--port N] [--profile hd|fullhd|qhd] [--seconds N]"
            );
            return ExitCode::from(2);
        }
    };
    let listener = match TcpListener::bind((args.bind.as_str(), args.port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("erro ao escutar em {}:{}: {e}", args.bind, args.port);
            return ExitCode::FAILURE;
        }
    };
    eprintln!(
        "aguardando cliente em {}:{} ({})",
        args.bind,
        args.port,
        args.profile.label()
    );
    let (stream, peer) = match listener.accept() {
        Ok(conn) => conn,
        Err(e) => {
            eprintln!("erro ao aceitar conexão: {e}");
            return ExitCode::FAILURE;
        }
    };
    eprintln!("cliente conectado: {peer}");
    let options = Options {
        profile: args.profile,
        seconds: args.seconds,
        ffmpeg: "ffmpeg".into(),
    };
    match serve_connection(stream, &options) {
        Ok(summary) => {
            eprintln!(
                "fim: {} frames de vídeo, {} keyframes",
                summary.video_frames, summary.keyframes
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("erro: {e}");
            ExitCode::FAILURE
        }
    }
}
