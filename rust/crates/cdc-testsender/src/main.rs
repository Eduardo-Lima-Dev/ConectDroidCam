//! Uso: cdc-testsender [--bind 127.0.0.1] [--port 47821] [--profile hd|fullhd|qhd] [--seconds 10]
//!                     [--rotation 0|90|180|270] [--rotate-after SEGUNDOS:ROTACAO]
//!                     [--advertise NOME] [--controllable]

use std::net::TcpListener;
use std::process::ExitCode;

use cdc_protocol::VideoProfile;
use cdc_testsender::{Options, serve_connection, serve_controllable};

struct Args {
    bind: String,
    port: u16,
    profile: VideoProfile,
    seconds: u32,
    rotation: u32,
    rotate_after: Option<(u32, u32)>,
    advertise: Option<String>,
    controllable: bool,
}

/// Registra o serviço mDNS e devolve o daemon, que precisa continuar vivo para ele existir.
fn advertise(nome: &str, porta: u16) -> Result<mdns_sd::ServiceDaemon, String> {
    use mdns_sd::{ServiceDaemon, ServiceInfo};
    let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
    let host = format!("{}.local.", nome.replace(' ', "-"));
    let info = ServiceInfo::new(
        "_conectdroidcam._tcp.local.",
        nome,
        &host,
        "",
        porta,
        &[("version", "test"), ("protocol", "1")][..],
    )
    .map_err(|e| e.to_string())?
    .enable_addr_auto();
    daemon.register(info).map_err(|e| e.to_string())?;
    Ok(daemon)
}

fn parse_rotation(texto: &str) -> Result<u32, String> {
    match texto.parse::<u32>() {
        Ok(r @ (0 | 90 | 180 | 270)) => Ok(r),
        _ => Err(format!("rotação inválida: {texto} (use 0, 90, 180 ou 270)")),
    }
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        bind: "127.0.0.1".into(),
        port: 47821,
        profile: VideoProfile::Hd,
        seconds: 10,
        rotation: 0,
        rotate_after: None,
        advertise: None,
        controllable: false,
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
            "--rotation" => {
                args.rotation = parse_rotation(&value("--rotation")?)?;
            }
            "--rotate-after" => {
                let v = value("--rotate-after")?;
                let (s, r) = v
                    .split_once(':')
                    .ok_or("use SEGUNDOS:ROTACAO, por exemplo 5:90")?;
                let s = s.parse().map_err(|_| "segundos inválidos".to_string())?;
                args.rotate_after = Some((s, parse_rotation(r)?));
            }
            "--controllable" => args.controllable = true,
            "--advertise" => args.advertise = Some(value("--advertise")?),
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
                "erro: {msg}\nuso: cdc-testsender [--bind IP] [--port N] [--profile hd|fullhd|qhd] [--seconds N] [--rotation R] [--rotate-after S:R]"
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
    // Anuncia na rede como o app do celular faria, para testar a descoberta sem aparelho.
    let _anuncio = match &args.advertise {
        Some(nome) => match advertise(nome, args.port) {
            Ok(daemon) => {
                eprintln!("anunciado na rede como \"{nome}\" (_conectdroidcam._tcp)");
                Some(daemon)
            }
            Err(e) => {
                eprintln!("erro ao anunciar na rede: {e}");
                return ExitCode::FAILURE;
            }
        },
        None => None,
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
        rotation: args.rotation,
        rotate_after: args.rotate_after,
        ..Options::new(args.profile, args.seconds)
    };
    if args.controllable {
        // Celular que espera ordens do computador: transmite só após `stream.start`.
        return match serve_controllable(stream, &options) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("erro: {e}");
                ExitCode::FAILURE
            }
        };
    }
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
